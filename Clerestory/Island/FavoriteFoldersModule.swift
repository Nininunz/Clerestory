import AppKit
import Foundation
import Observation
import OSLog

struct FavoriteFolder: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var bookmark: Data
    var lastKnownPath: String
    var customDisplayName: String?
    let addedAt: Date

    init(
        id: UUID = UUID(),
        bookmark: Data,
        lastKnownPath: String,
        customDisplayName: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.customDisplayName = customDisplayName
        self.addedAt = addedAt
    }

    var displayName: String {
        if let customDisplayName,
           !customDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customDisplayName
        }
        let url = URL(fileURLWithPath: lastKnownPath, isDirectory: true)
        return url.lastPathComponent.isEmpty ? lastKnownPath : url.lastPathComponent
    }

    var parentDisplayName: String {
        let parent = URL(fileURLWithPath: lastKnownPath, isDirectory: true)
            .deletingLastPathComponent()
        return parent.lastPathComponent.isEmpty ? parent.path : parent.lastPathComponent
    }
}

private struct FavoriteFoldersSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var items: [FavoriteFolder]
}

@MainActor
final class FavoriteFoldersPersistenceController {
    static let currentSchemaVersion = 1

    enum LoadResult: Equatable, Sendable {
        case loaded([FavoriteFolder])
        case missing
        case failed

        var items: [FavoriteFolder] {
            guard case .loaded(let items) = self else { return [] }
            return items
        }
    }

    let directoryURL: URL
    let debounceInterval: Duration

    private var fileURL: URL {
        directoryURL.appendingPathComponent("folder-favorites.json")
    }
    private var backupURL: URL {
        directoryURL.appendingPathComponent("folder-favorites.json.backup")
    }
    private var pendingItems: [FavoriteFolder]?
    private var saveTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: "com.nininunz.Clerestory",
        category: "FavoriteFoldersPersistence"
    )

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    init(
        directoryURL: URL? = nil,
        debounceInterval: Duration = .milliseconds(500)
    ) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
        self.debounceInterval = debounceInterval
    }

    func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(FavoriteFoldersSnapshot.self, from: data)
            if snapshot.schemaVersion > Self.currentSchemaVersion {
                logger.warning("folder-favorites.json uses a newer schema; decoding best-effort")
            }
            return .loaded(snapshot.items)
        } catch {
            logger.error("Failed to load folder favorites: \(error.localizedDescription, privacy: .public)")
            quarantineCorruptFile()
            return .failed
        }
    }

    func scheduleSave(_ items: [FavoriteFolder]) {
        pendingItems = items
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled, let pendingItems else { return }
            self.pendingItems = nil
            writeOrLog(pendingItems)
        }
    }

    func saveNow(_ items: [FavoriteFolder]) throws {
        saveTask?.cancel()
        saveTask = nil
        pendingItems = nil
        try write(items)
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let pendingItems else { return }
        self.pendingItems = nil
        writeOrLog(pendingItems)
    }

    private func writeOrLog(_ items: [FavoriteFolder]) {
        do {
            try write(items)
        } catch {
            logger.error("Failed to save folder favorites: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ items: [FavoriteFolder]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let snapshot = FavoriteFoldersSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            items: items
        )
        let data = try encoder.encode(snapshot)

        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let previousData = try Data(contentsOf: fileURL)
                _ = try decoder.decode(FavoriteFoldersSnapshot.self, from: previousData)
                try previousData.write(to: backupURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh the folder-favorites backup")
            }
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptFile() {
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let quarantineURL = directoryURL.appendingPathComponent(
            "folder-favorites.json.corrupt-\(suffix)"
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
        } catch {
            logger.error("Could not quarantine damaged folder favorites")
        }
    }
}

@MainActor
protocol FavoriteFolderOpening: AnyObject {
    func defaultApplicationURL(for folderURL: URL) -> URL?
    func applicationURLs(for folderURL: URL) -> [URL]
    func open(
        _ folderURL: URL,
        with applicationURL: URL?,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    )
}

@MainActor
final class SystemFavoriteFolderOpener: FavoriteFolderOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func defaultApplicationURL(for folderURL: URL) -> URL? {
        workspace.urlForApplication(toOpen: folderURL)
    }

    func applicationURLs(for folderURL: URL) -> [URL] {
        workspace.urlsForApplications(toOpen: folderURL)
    }

    func open(
        _ folderURL: URL,
        with applicationURL: URL?,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        let finished: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(message) }
        }

        if let applicationURL {
            workspace.open(
                [folderURL],
                withApplicationAt: applicationURL,
                configuration: configuration,
                completionHandler: finished
            )
        } else {
            workspace.open(
                folderURL,
                configuration: configuration,
                completionHandler: finished
            )
        }
    }
}

struct FavoriteFolderImportSummary: Equatable, Sendable {
    var added = 0
    var duplicates = 0
    var rejected = 0
}

private enum FavoriteFolderError: LocalizedError {
    case notDirectory
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            String(localized: "Only folders can be added to Quick Access.")
        case .unavailable:
            String(localized: "This folder is not available.")
        }
    }
}

@MainActor
@Observable
final class FavoriteFoldersStore {
    private(set) var items: [FavoriteFolder]
    private(set) var selectedID: UUID?
    private(set) var unavailableIDs: Set<UUID> = []
    /// The saved favorites could not be read at launch. The page shows it until a folder is
    /// added, which saves a fresh list over the damaged one.
    private(set) var didFailToLoad = false
    private(set) var isRunning = false

    @ObservationIgnored private let persistence: FavoriteFoldersPersistenceController?
    @ObservationIgnored private let bookmarkService: BookmarkService
    @ObservationIgnored private let opener: any FavoriteFolderOpening
    /// Where Quick Access posts what just happened, such as "Folder added to Quick Access."
    @ObservationIgnored private let messenger: ModuleMessenger
    @ObservationIgnored private var hasLoaded = false

    init(
        items: [FavoriteFolder] = [],
        persistence: FavoriteFoldersPersistenceController? = nil,
        bookmarkService: BookmarkService,
        opener: any FavoriteFolderOpening = SystemFavoriteFolderOpener(),
        messenger: ModuleMessenger = .inert,
        itemsAreLoaded: Bool = false
    ) {
        self.items = items
        self.persistence = persistence
        self.bookmarkService = bookmarkService
        self.opener = opener
        self.messenger = messenger
        self.hasLoaded = itemsAreLoaded
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let persistence else { return }
        switch persistence.loadResult() {
        case .loaded(let loadedItems):
            items = loadedItems
        case .missing:
            items = []
        case .failed:
            items = []
            didFailToLoad = true
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        persistence?.flushPendingSave()
    }

    func addFolders(_ urls: [URL]) -> FavoriteFolderImportSummary {
        if !hasLoaded { start() }
        var summary = FavoriteFolderImportSummary()
        var newItems: [FavoriteFolder] = []

        for url in urls {
            do {
                try validateFolder(url)
                if duplicateID(for: url) != nil {
                    summary.duplicates += 1
                    continue
                }
                let bookmark = try bookmarkService.createBookmark(for: url)
                newItems.append(FavoriteFolder(
                    bookmark: bookmark,
                    lastKnownPath: normalizedPath(url)
                ))
                summary.added += 1
            } catch {
                summary.rejected += 1
            }
        }

        if !newItems.isEmpty {
            items.append(contentsOf: newItems)
            selectedID = newItems.last?.id
            if didFailToLoad { didFailToLoad = false }
            persist()
        }
        postNotice(for: summary)
        return summary
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        unavailableIDs.remove(id)
        if selectedID == id {
            selectedID = items.indices.contains(index)
                ? items[index].id
                : items.last?.id
        }
        persist()
    }

    func copyDestinationBookmark(for id: UUID) -> Data? {
        guard let item = items.first(where: { $0.id == id }),
              let url = try? bookmarkService.resolve(item.bookmark).url else { return nil }
        return bookmarkService.withSecurityScopedAccess(to: url) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return item.bookmark
        }
    }

    func move(_ sourceID: UUID, before destinationID: UUID) {
        guard sourceID != destinationID,
              let source = items.firstIndex(where: { $0.id == sourceID }),
              let destination = items.firstIndex(where: { $0.id == destinationID }) else {
            return
        }
        let item = items.remove(at: source)
        let adjustedDestination = source < destination ? destination - 1 : destination
        items.insert(item, at: adjustedDestination)
        persist()
    }

    func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    @discardableResult
    func selectRelative(delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        guard let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = items.first?.id
            return true
        }
        let next = min(max(index + delta, 0), items.count - 1)
        self.selectedID = items[next].id
        return true
    }

    @discardableResult
    func openSelected() -> Bool {
        guard let selectedID else { return false }
        return open(selectedID)
    }

    @discardableResult
    func removeSelected() -> Bool {
        guard let selectedID else { return false }
        remove(selectedID)
        return true
    }

    @discardableResult
    func open(_ id: UUID, with applicationURL: URL? = nil) -> Bool {
        guard let url = resolveURL(for: id, refreshStaleBookmark: true) else {
            return false
        }
        _ = bookmarkService.startAccessing(url)
        opener.open(url, with: applicationURL) { [weak self, bookmarkService] errorMessage in
            bookmarkService.stopAccessing(url)
            guard let self else { return }
            if let errorMessage {
                self.unavailableIDs.insert(id)
                self.messenger.post(Self.openFailedNotice(reason: errorMessage))
            } else {
                self.unavailableIDs.remove(id)
                self.messenger.withdrawNotice(Self.openFailedKey)
            }
        }
        return true
    }

    func applicationURLs(for id: UUID) -> [URL] {
        guard let item = item(withID: id),
              let resolved = try? bookmarkService.resolve(item.bookmark) else {
            return []
        }
        return opener.applicationURLs(for: resolved.url)
    }

    func defaultApplicationURL(for id: UUID) -> URL? {
        guard let item = item(withID: id),
              let resolved = try? bookmarkService.resolve(item.bookmark) else {
            return nil
        }
        return opener.defaultApplicationURL(for: resolved.url)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].customDisplayName = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    @discardableResult
    func relocate(_ id: UUID, to url: URL) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        do {
            try validateFolder(url)
            items[index].bookmark = try bookmarkService.createBookmark(for: url)
            items[index].lastKnownPath = normalizedPath(url)
            unavailableIDs.remove(id)
            persist()
            messenger.withdrawNotice(Self.openFailedKey)
            messenger.withdrawNotice(Self.relocateFailedKey)
            return true
        } catch {
            messenger.post(IslandNotice(key: Self.relocateFailedKey, title: error.localizedDescription, tone: .error))
            return false
        }
    }

    func isUnavailable(_ id: UUID) -> Bool {
        unavailableIDs.contains(id)
    }

    func canImportFolders(from pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(from: pasteboard)
        return !urls.isEmpty && urls.allSatisfy { (try? validateFolder($0)) != nil }
    }

    @discardableResult
    func importFolders(from pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        _ = addFolders(urls)
        return true
    }

    private func item(withID id: UUID) -> FavoriteFolder? {
        items.first { $0.id == id }
    }

    private func resolveURL(
        for id: UUID,
        refreshStaleBookmark: Bool
    ) -> URL? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        do {
            let resolved = try bookmarkService.resolve(items[index].bookmark)
            try validateFolder(resolved.url)
            if refreshStaleBookmark && resolved.isStale {
                items[index].bookmark = try bookmarkService.createBookmark(for: resolved.url)
                items[index].lastKnownPath = normalizedPath(resolved.url)
                persist()
            }
            unavailableIDs.remove(id)
            return resolved.url
        } catch {
            // The tile turns orange and reads "Unavailable", and its menu has Locate Again,
            // so no notice repeats that.
            unavailableIDs.insert(id)
            return nil
        }
    }

    private func validateFolder(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true else {
            throw FavoriteFolderError.notDirectory
        }
    }

    private func duplicateID(for url: URL) -> UUID? {
        let path = normalizedPath(url)
        for item in items {
            if normalizedPath(URL(fileURLWithPath: item.lastKnownPath, isDirectory: true)) == path {
                return item.id
            }
            if let resolved = try? bookmarkService.resolve(item.bookmark),
               normalizedPath(resolved.url) == path {
                return item.id
            }
        }
        return nil
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []
        return objects.compactMap { object in
            (object as? NSURL).map { $0 as URL }
        }
    }

    private func persist() {
        persistence?.scheduleSave(items)
    }

    private func postNotice(for summary: FavoriteFolderImportSummary) {
        if let notice = Self.importNotice(for: summary) { messenger.post(notice) }
    }
}

extension FavoriteFoldersStore {
    static let openFailedKey = "open-failed"
    static let relocateFailedKey = "relocate-failed"

    /// What adding folders reports: added, already there, or some rejected. `nil` when
    /// nothing was dropped.
    static func importNotice(for summary: FavoriteFolderImportSummary) -> IslandNotice? {
        if summary.added > 0 {
            return IslandNotice(
                key: "added",
                title: summary.added == 1
                    ? String(localized: "Folder added to Quick Access.")
                    : String(localized: "Folders added to Quick Access."),
                tone: .success
            )
        } else if summary.duplicates > 0 && summary.rejected == 0 {
            return IslandNotice(key: "duplicate", title: String(localized: "This folder is already in Quick Access."))
        } else if summary.rejected > 0 {
            return IslandNotice(key: "add-failed", title: String(localized: "Some folders could not be added."),
                                tone: .error)
        }
        return nil
    }

    /// The pill names the failure; the tooltip and VoiceOver add the reason.
    static func openFailedNotice(reason: String) -> IslandNotice {
        let title = String(localized: "Could not open this folder.")
        return IslandNotice(key: openFailedKey, title: title, detail: title + " " + reason, tone: .error)
    }
}

#if DEBUG
// Isolated, non-running fixtures for the module preview catalog. Never used by app startup.
extension FavoriteFoldersStore {
    static func preview(items: [FavoriteFolder] = [], unavailable: Bool = false, loadFailed: Bool = false) -> FavoriteFoldersStore {
        let store = FavoriteFoldersStore(items: items, bookmarkService: BookmarkService(), itemsAreLoaded: true)
        store.didFailToLoad = loadFailed
        if unavailable { store.unavailableIDs = Set(items.map(\.id)) }
        return store
    }
}
#endif
