import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardHistoryStore {
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var isRecording = false
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    var shortcutRegistrationError: String?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let persistence: ClipboardHistoryPersistence
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastChangeCount: Int
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var canWrite = true
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// The one background re-encode of an oversized image, if any.
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    /// Bumped by Clear History and when recording stops, so a re-encode that
    /// was already running can't add its image afterwards.
    @ObservationIgnored private var captureGeneration = 0
    /// Keeps the lazy TIFF for the last JPEG entry copied back to the clipboard.
    @ObservationIgnored private var tiffProvider: ClipboardTIFFProvider?
    @ObservationIgnored nonisolated(unsafe) private var resourceToken: NSObjectProtocol?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sourceIsIgnored: () -> Bool
    var onAddToShelf: ((ClipboardHistoryEntry.Content) -> Void)?
    var onShowWindow: (() -> Void)?

    init(settings: SettingsStore, pasteboard: NSPasteboard = .general,
         directoryURL: URL = AppDirectories.applicationSupport(), now: @escaping () -> Date = Date.init,
         sourceIsIgnored: (() -> Bool)? = nil) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.persistence = ClipboardHistoryPersistence(directoryURL: directoryURL)
        self.now = now
        self.sourceIsIgnored = sourceIsIgnored ?? {
            IgnoreListService.frontmostAppIsIgnored(in: settings.ignoredAppBundleIDs)
        }
        lastChangeCount = pasteboard.changeCount
        _ = ResourceUsageState.shared
        resourceToken = NotificationCenter.default.addObserver(forName: .clerestoryResourcePolicyDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateRecording() }
        }
    }

    deinit {
        pollTask?.cancel()
        imageTask?.cancel()
        loadTask?.cancel()
        saveTask?.cancel()
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
    }

    func start() {
        isStarted = true
        if loadTask == nil && isLoading {
            loadTask = Task { @MainActor [weak self, persistence] in
                do {
                    let loaded = try await persistence.load()
                    guard let self, !Task.isCancelled else { return }
                    if revision == 0 {
                        entries = ClipboardHistoryPolicy.trimmed(loaded, now: now(), retentionDays: settings.clipboardHistoryRetentionDays,
                                                                 entryLimit: settings.clipboardHistoryEntryLimit)
                        if entries != loaded { persist() }
                    }
                } catch {
                    guard let self else { return }
                    if revision == 0 {
                        canWrite = false
                        errorMessage = String(localized: "Clipboard history could not be loaded. Clear history to reset it.")
                    }
                }
                guard let self else { return }
                isLoading = false
                updateRecording()
            }
        }
        updateRecording()
    }

    func stop() {
        isStarted = false
        stopPolling()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        cancelImageTask()
        isRecording = false
        lastChangeCount = pasteboard.changeCount
    }

    func updateRecording() {
        prune()
        guard isStarted, !isLoading, settings.clipboardHistoryEnabled, !settings.clipboardHistoryPaused,
              ResourceUsageState.shared.samplingAllowed else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }
        // Opting in / resuming never retroactively captures existing contents.
        lastChangeCount = pasteboard.changeCount
        isRecording = true
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    func poll() {
        guard isRecording, settings.clipboardHistoryEnabled, !settings.clipboardHistoryPaused else { return }
        prune()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        // What the copied items wrote, and everything AppKit could convert to.
        let itemTypes = Set((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        let types = itemTypes.union((pasteboard.types ?? []).map(\.rawValue))
        let isFileCopy = ClipboardHistoryPolicy.isFileCopy(types)
        let fileURLs = isFileCopy
            ? (pasteboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            : []
        guard ClipboardHistoryPolicy.permits(types: types, itemTypes: itemTypes, fileURLs: fileURLs,
                                             sourceIsIgnored: sourceIsIgnored()) else { return }
        let copiedAt = now()
        var image: ClipboardHistoryEntry.Content?
        var oversizedImage: Data?
        // Read TIFF only when there is no PNG: asking for it makes AppKit
        // convert a PNG-only copy into a large uncompressed bitmap.
        for type in [NSPasteboard.PasteboardType.png, .tiff] where image == nil && oversizedImage == nil {
            guard let data = pasteboard.data(forType: type) else { continue }
            if data.count <= ClipboardHistoryPolicy.maximumImageBytes {
                image = .image(data, type: type.rawValue)
            } else {
                oversizedImage = data
            }
        }
        // The link or text, kept when there is no image or an oversized one
        // can't be made to fit.
        var fallback: ClipboardHistoryEntry.Content?
        if image == nil, !isFileCopy {
            if let value = pasteboard.string(forType: .URL), ClipboardHistoryEntry.Content.url(value).isValid {
                fallback = .url(value)
            } else if let value = pasteboard.string(forType: .string) {
                fallback = ClipboardHistoryEntry.Content.url(value).isValid ? .url(value) : .text(value)
            }
        }
        guard pasteboard.changeCount == changeCount else { return }
        if let oversizedImage {
            // This copy replaces any image still being re-encoded.
            cancelImageTask()
            let generation = captureGeneration
            imageTask = Task.detached(priority: .utility) { [weak self] in
                let reencoded = ClipboardHistoryPolicy.reencodedImage(oversizedImage)
                guard !Task.isCancelled,
                      let content = reencoded.map({ .image($0.data, type: $0.type) }) ?? fallback else { return }
                await self?.record(content, copiedAt: copiedAt, generation: generation)
            }
            return
        }
        guard let content = image ?? fallback else { return }
        cancelImageTask()
        record(content, copiedAt: copiedAt)
    }

    private func cancelImageTask() {
        imageTask?.cancel()
        imageTask = nil
        captureGeneration += 1
    }

    private func record(_ content: ClipboardHistoryEntry.Content, copiedAt: Date, generation: Int? = nil) {
        // A re-encode can finish after the user paused, turned history off,
        // cleared it, or copied something newer.
        guard isRecording, content.isValid, generation == nil || generation == captureGeneration else { return }
        let next = ClipboardHistoryPolicy.inserting(content, into: entries, now: copiedAt, retentionDays: settings.clipboardHistoryRetentionDays,
                                                     entryLimit: settings.clipboardHistoryEntryLimit)
        guard next.contains(where: { $0.content == content }) else {
            noticeMessage = String(localized: "History storage is full. Remove a favorite or an image to record more.")
            return
        }
        entries = next
        persist()
    }

    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        let item = NSPasteboardItem()
        switch entry.content {
        case .text(let value): item.setString(value, forType: .string)
        case .url(let value):
            item.setString(value, forType: .URL)
            item.setString(value, forType: .string)
        case .image(let data, let type):
            item.setData(data, forType: .init(type))
            // Many apps paste only PNG or TIFF. Build the TIFF only if one asks.
            if type == UTType.jpeg.identifier {
                let provider = ClipboardTIFFProvider(jpeg: data)
                item.setDataProvider(provider, forTypes: [.tiff])
                tiffProvider = provider
            }
        }
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
        noticeMessage = success ? String(localized: "Copied to Clipboard") : String(localized: "Copy failed")
        return success
    }

    func addToShelf(_ entry: ClipboardHistoryEntry) {
        onAddToShelf?(entry.content)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist(immediately: true)
    }

    func clear() {
        cancelImageTask()
        tiffProvider = nil
        entries = []
        lastChangeCount = pasteboard.changeCount
        canWrite = true
        errorMessage = nil
        noticeMessage = nil
        persist(immediately: true)
    }

    func setFavorite(_ favorite: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if favorite && !entries[index].isFavorite,
           entries.filter(\.isFavorite).count >= ClipboardHistoryPolicy.maximumFavorites {
            noticeMessage = String(localized: "You can keep up to 30 favorites.")
            return
        }
        entries[index].isFavorite = favorite
        prune(force: true)
        persist()
    }

    func filteredEntries(query: String, filter: ClipboardContentFilter = .all) -> [ClipboardHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            filter.includes($0) && (query.isEmpty || $0.content.searchText.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.copiedAt > $1.copiedAt
        }
    }

    func prune(force: Bool = false) {
        guard force || now().timeIntervalSince(lastPrune) >= 60 else { return }
        lastPrune = now()
        let trimmed = ClipboardHistoryPolicy.trimmed(entries, now: now(), retentionDays: settings.clipboardHistoryRetentionDays,
                                                     entryLimit: settings.clipboardHistoryEntryLimit)
        guard entries != trimmed else { return }
        entries = trimmed
        persist()
    }

    private func persist(immediately: Bool = false) {
        guard canWrite else { return }
        saveTask?.cancel()
        revision += 1
        let revision = revision
        let entries = entries
        saveTask = Task { @MainActor [weak self, persistence] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                try await persistence.save(entries, revision: revision)
                if self?.revision == revision { self?.errorMessage = nil }
            } catch {
                if self?.revision == revision {
                    self?.errorMessage = String(localized: "Clipboard history could not be saved.")
                }
            }
        }
    }

    func flush() async {
        if isLoading {
            guard let loadTask else { return }
            await loadTask.value
        }
        guard canWrite else { return }
        saveTask?.cancel()
        revision += 1
        do {
            try await persistence.save(entries, revision: revision)
        } catch {
            errorMessage = String(localized: "Clipboard history could not be saved.")
        }
    }
}

#if DEBUG
// Isolated, non-running fixtures for the module preview catalog. Never used by app startup.
extension ClipboardHistoryStore {
    static func preview(settings: SettingsStore, directory: URL, entries: [ClipboardHistoryEntry] = [], loading: Bool = false, error: String? = nil, notice: String? = nil) -> ClipboardHistoryStore {
        let store = ClipboardHistoryStore(settings: settings, pasteboard: NSPasteboard(name: .init("Clerestory.ModulePreviews")), directoryURL: directory)
        store.entries = entries
        store.isLoading = loading
        store.errorMessage = error
        store.noticeMessage = notice
        return store
    }
}
#endif

/// Supplies TIFF for a JPEG history entry copied back to the clipboard, but
/// only when a paste target asks for it. Building it up front would decode a
/// photo of up to 32 MP into a large uncompressed bitmap on the main thread.
nonisolated final class ClipboardTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let jpeg: Data

    init(jpeg: Data) {
        self.jpeg = jpeg
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        item.setData(output as Data, forType: .tiff)
    }
}
