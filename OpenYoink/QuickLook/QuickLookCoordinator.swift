import AppKit
import OSLog
import QuickLookUI
import SwiftUI

/// Plans the Quick Look preview without depending on Quick Look windows.
///
/// 1. A context item in the selection previews the selection in display order,
///    starting at that item.
/// 2. A context item outside the selection previews only that item.
/// 3. Space supplies no context item and previews the current selection.
///
/// Expand stacks recursively and omit stale items whose bookmarks no longer
/// resolve. The context menu labels these items “File Unavailable.”
enum QuickLookPreviewPlanner {
    /// Returns the preview entries after expanding stacks and filtering stale items.
    static func previewItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        flatten(baseItems(selection: selection, contextItem: contextItem))
            .filter { !$0.isStale }
    }

    /// Returns the context item's index in the flattened list, or zero if absent.
    static func currentIndex(in previewItems: [ShelfItem], contextItem: ShelfItem?) -> Int {
        guard let contextItem,
              let index = previewItems.firstIndex(where: { $0.id == contextItem.id }) else {
            return 0
        }
        return index
    }

    /// Applies the selection rules before expanding stacks and filtering stale items.
    static func baseItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        if let contextItem, !selection.contains(where: { $0.id == contextItem.id }) {
            return [contextItem]
        }
        if !selection.isEmpty {
            return selection
        }
        return contextItem.map { [$0] } ?? []
    }

    /// Expands stacks recursively and preserves other items.
    static func flatten(_ items: [ShelfItem]) -> [ShelfItem] {
        items.flatMap { item -> [ShelfItem] in
            if item.kind == .stack, let children = item.children {
                return flatten(children)
            }
            return [item]
        }
    }
}

// MARK: - Item actions (Open / Show in Finder)

/// Stateless actions for opening Shelf items and revealing them in Finder.
/// The context menu and tests share the availability checks. The menu displays
/// “File Unavailable” for stale items. These actions never delete originals.
@MainActor
enum ItemActions {
    // MARK: Availability

    /// Files, folders, and images need a path and must be available. Text needs
    /// content, URLs need a URL string, and stacks need a previewable child.
    static func canQuickLook(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .file, .folder, .image:
            return !item.isStale && item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return !(item.urlString?.isEmpty ?? true)
        case .stack:
            return (item.children ?? []).contains(where: canQuickLook)
        }
    }

    /// NSWorkspace opens resolved file, folder, image, and web URLs. Text is
    /// written to a temporary file before opening. Stacks have no Open action.
    static func canOpen(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return item.urlString.flatMap(URL.init(string:)) != nil
        case .stack:
            return false
        }
    }

    /// Finder can reveal resolved file, folder, and image URLs, including materialized
    /// files, and the temporary file for a text item. URLs and stacks lack a single local file.
    static func canRevealInFinder(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url, .stack:
            return false
        }
    }

    // MARK: Actions

    /// Opens the item if canOpen permits it.
    static func open(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canOpen(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            // Acquire security-scoped access before passing the URL to LaunchServices.
            bookmarkService.withSecurityScopedAccess(to: url) {
                _ = NSWorkspace.shared.open(url)
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.open(url)
        case .url:
            guard let urlString = item.urlString, let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        case .stack:
            break
        }
    }

    /// Reveals the item in Finder if canRevealInFinder permits it.
    static func revealInFinder(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canRevealInFinder(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            bookmarkService.withSecurityScopedAccess(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .url, .stack:
            break
        }
    }

    // MARK: Shared helpers

    /// When a bookmark exists, its resolution is authoritative. A stored path
    /// can identify a missing file or help the user reconnect it. Using that
    /// path as a fallback would bypass the sandbox boundary set by the user's
    /// grant. Legacy items without bookmarks still use their original fileURL.
    static func resolveFileURL(for item: ShelfItem, bookmarkService: BookmarkService) -> URL? {
        if let bookmark = item.bookmark {
            return try? bookmarkService.resolve(bookmark).url
        }
        return item.fileURL
    }

    /// Preview, Open, and Reveal in Finder share this temporary text writer.
    /// TempFileService writes inside the sandbox container. The caller owns
    /// session cleanup, and the startup orphan sweep handles leftovers.
    static func writeTextToTemporaryFile(_ text: String, suggestedName: String, tempFileService: TempFileService) throws -> URL {
        // uniqueFileURL takes the last path component and prefixes it with a UUID.
        let url = try tempFileService.uniqueFileURL(suggestedName: suggestedName + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - QuickLookCoordinator

/// Owns the Quick Look session and serves as the shared preview panel's
/// data source and delegate.
///
/// The preview can become key through `makeKeyAndOrderFront` while the
/// frontmost application stays active. Quick Look handles Space, Escape,
/// and preview navigation. Shelf routes its own keyboard events to the
/// coordinator and synchronizes selection with navigation.
///
/// The session keeps security-scoped access open for file previews and
/// releases it at teardown. Text and URL items preview as temporary text
/// files. Showing the URL itself avoids network latency and failures when
/// the user presses Space. The planner expands stacks into their children.
///
/// ShelfWindowController owns the coordinator and injects it into cards
/// through the SwiftUI environment. Preview and test hosts that omit it
/// disable Quick Look actions.
///
/// The SDK leaves the Objective-C Quick Look protocols actor-unannotated.
/// The isolated conformances match Quick Look's main-thread callbacks.
@MainActor
final class QuickLookCoordinator: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    /// Pairs a Shelf item with its Quick Look item and session resources.
    private struct PreviewEntry {
        let source: ShelfItem
        let previewItem: ShelfPreviewItem
    }

    private let store: ShelfStore
    private let bookmarkService: BookmarkService
    private let tempFileService: TempFileService
    private let logger = Logger(subsystem: "com.nininunz.OpenYoink", category: "QuickLook")

    /// Centralizes access to Quick Look's shared process-wide panel, which the SDK declares optional.
    private var sharedPanel: QLPreviewPanel? { QLPreviewPanel.shared() }

    /// The current preview entries. Toggling the same source list again closes the panel.
    private var session: [PreviewEntry] = []
    /// Install the close observer lazily to avoid creating the shared panel at startup.
    private var didInstallCloseObserver = false

    /// Returns keyboard focus to Shelf after a user-initiated close without activating the app.
    var onPanelClosed: (() -> Void)?
    var onPreviewVisibilityChanged: ((Bool) -> Void)?
    /// Resolve the currently visible source window, including the elevated Island.
    var onNavigationKey: ((NSEvent) -> Bool)?
    var sourceWindowLevel: (() -> NSWindow.Level)?
    private var originalPanelLevel: NSWindow.Level?


    init(store: ShelfStore, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        self.store = store
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Check for a session first to avoid creating the panel before Quick Look is used.
    var isPreviewing: Bool {
        guard !session.isEmpty else { return false }
        return sharedPanel?.isVisible ?? false
    }

    // MARK: - Session control

    /// Toggling the source list already on screen closes the panel. A different
    /// list replaces the session or opens the panel. Returns whether the event was handled.
    @discardableResult
    func toggle(contextItem: ShelfItem?) -> Bool {
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        let panelVisible = !session.isEmpty && (sharedPanel?.isVisible ?? false)
        if panelVisible, sourceItems == session.map(\.source) {
            dismiss()
            return true
        }
        guard !sourceItems.isEmpty else {
            if panelVisible { dismiss() }
            return false
        }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: true)
        return !session.isEmpty
    }

    /// Update an open preview as selection changes. An empty selection leaves
    /// the current preview in place. Refreshing preserves keyboard focus.
    func refreshPreview(contextItem: ShelfItem?) {
        guard !session.isEmpty, sharedPanel?.isVisible == true else { return }
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        guard !sourceItems.isEmpty, sourceItems != session.map(\.source) else { return }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: false)
    }

    /// Closes a user-dismissed preview, releases resources, and lets Shelf become key again.
    func dismiss() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
        onPreviewVisibilityChanged?(false)
        onPanelClosed?()
    }

    /// Closes the preview and releases resources while Shelf is hiding, without restoring focus.
    func closeForShelfHide() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
        onPreviewVisibilityChanged?(false)
    }

    // MARK: - Session internals

    /// Creates or replaces a preview session. Bring the panel forward and make
    /// it key on initial presentation or an explicit focus request. Selection
    /// refreshes leave keyboard focus in place.
    private func present(_ sourceItems: [ShelfItem], contextItem: ShelfItem?, grabKeyFocus: Bool) {
        buildSession(from: sourceItems)
        guard !session.isEmpty, let panel = sharedPanel else { return }
        panel.setAccessibilityIdentifier("shelf.quickLook")
        installCloseObserverIfNeeded()
        // Reassign the shared panel's data source and delegate for every session.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = QuickLookPreviewPlanner.currentIndex(
            in: session.map(\.source), contextItem: contextItem
        )
        originalPanelLevel = panel.level
        let previewLevel = Self.previewLevel(original: panel.level, source: sourceWindowLevel?())
        panel.level = previewLevel
        if grabKeyFocus || !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.level = previewLevel
        onPreviewVisibilityChanged?(panel.isVisible)
    }

    /// Releases the previous session, then resolves each preview URL. Log and
    /// skip individual failures so the remaining items can still be previewed.
    private func buildSession(from sourceItems: [ShelfItem]) {
        endSession()
        var entries: [PreviewEntry] = []
        for item in sourceItems {
            if let previewItem = makePreviewItem(for: item) {
                entries.append(PreviewEntry(source: item, previewItem: previewItem))
            } else {
                logger.error("Skipping Quick Look item '\(item.displayName, privacy: .public)': could not resolve a preview URL")
            }
        }
        session = entries
    }

    /// Releases security-scoped access and temporary text files owned by the session.
    static func previewLevel(original: NSWindow.Level, source: NSWindow.Level?) -> NSWindow.Level {
        guard let source else { return original }
        return NSWindow.Level(rawValue: max(original.rawValue, source.rawValue + 1))
    }

    private func endSession() {
        if let originalPanelLevel {
            sharedPanel?.level = originalPanelLevel
            self.originalPanelLevel = nil
        }

        for entry in session {
            if let accessedURL = entry.previewItem.accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
            if let temporaryFileURL = entry.previewItem.temporaryFileURL {
                try? tempFileService.removeMaterializedFile(at: temporaryFileURL)
            }
        }
        session = []
    }

    /// Creates one Quick Look item from a resolved file or temporary text file.
    private func makePreviewItem(for item: ShelfItem) -> ShelfPreviewItem? {
        switch item.kind {
        case .file, .folder, .image:
            guard let url = ItemActions.resolveFileURL(for: item, bookmarkService: bookmarkService) else {
                return nil
            }
            // endSession balances each successful access. BookmarkService already
            // rolls back its reference count when starting access fails.
            let accessedURL = bookmarkService.startAccessing(url) ? url : nil
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: accessedURL, temporaryFileURL: nil)
        case .text:
            guard let text = item.text, !text.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .url:
            // Preview the URL as text without fetching the remote resource.
            guard let urlString = item.urlString, !urlString.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(urlString, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .stack:
            // The planner expands stacks before constructing preview items.
            return nil
        }
    }

    // MARK: - Panel close observation

    private func installCloseObserverIfNeeded() {
        guard !didInstallCloseObserver else { return }
        didInstallCloseObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: QLPreviewPanel.shared()
        )
    }

    /// Clean up when Quick Look sends a close notification. Some system versions
    /// only order the panel out. In that case, the next session, Shelf dismissal,
    /// or app shutdown will release the resources.
    @objc private func panelWillClose(_ notification: Notification) {
        endSession()
        onPreviewVisibilityChanged?(false)
        onPanelClosed?()
    }
}

// MARK: - QLPreviewPanelDataSource / QLPreviewPanelDelegate

/// Quick Look data source and delegate methods. The system handles the
/// standard transition and keyboard actions that the delegate leaves unhandled.
extension QuickLookCoordinator {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              [123, 124, 125, 126].contains(event.keyCode) else { return false }
        return onNavigationKey?(event) ?? false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        session.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard session.indices.contains(index) else { return nil }
        return session[index].previewItem
    }
}

// MARK: - ShelfPreviewItem

/// Wraps a preview URL and title with resources that QuickLookCoordinator
/// releases when the session ends.
private final class ShelfPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    /// The URL whose security-scoped access was successfully started, if any.
    let accessedURL: URL?
    /// A text or URL preview's temporary file, removed when the session ends.
    let temporaryFileURL: URL?

    init(url: URL, title: String, accessedURL: URL?, temporaryFileURL: URL?) {
        self.previewItemURL = url
        self.previewItemTitle = title
        self.accessedURL = accessedURL
        self.temporaryFileURL = temporaryFileURL
        super.init()
    }
}

// MARK: - SwiftUI environment

private struct QuickLookCoordinatorEnvironmentKey: EnvironmentKey {
    // Preview and test hosts can omit the coordinator to disable Quick Look actions.
    static var defaultValue: QuickLookCoordinator? { nil }
}

private struct TempFileServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = TempFileService()
}

extension EnvironmentValues {
    /// ShelfWindowController injects the coordinator at the panel content root.
    var quickLookCoordinator: QuickLookCoordinator? {
        get { self[QuickLookCoordinatorEnvironmentKey.self] }
        set { self[QuickLookCoordinatorEnvironmentKey.self] = newValue }
    }

    /// Directory for temporary text and URL files used by item actions.
    var tempFileService: TempFileService {
        get { self[TempFileServiceEnvironmentKey.self] }
        set { self[TempFileServiceEnvironmentKey.self] = newValue }
    }
}
