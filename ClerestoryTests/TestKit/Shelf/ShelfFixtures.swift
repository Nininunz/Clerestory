import Foundation
@testable import Clerestory

/// Fresh values per call; no user files, bookmarks, persistence, or services.
enum ShelfFixtures {
    static func notes(count: Int) -> [ShelfItem] {
        (0..<count).map { ShelfItem(kind: .text, displayName: "Project note \($0 + 1)", text: "Sample \($0 + 1)") }
    }

    @MainActor
    static func mixedItems() throws -> [ShelfItem] {
        let urls = try ShelfSampleFiles.shared.get()
        var items = urls.map { url in
            ShelfItem(kind: url.hasDirectoryPath ? .folder : url.pathExtension == "png" ? .image : .file,
                      path: url.path, displayName: url.lastPathComponent)
        }
        var offline = ShelfItem(kind: .file, displayName: "Archived proposal.pdf")
        offline.availability = .externalFileOffline
        items.append(offline)
        return items
    }

    @MainActor
    static func manyFiles() throws -> [ShelfItem] {
        try ShelfSampleFiles.manyItems.get().map(fileItem)
    }

    @MainActor
    static func longNames() throws -> [ShelfItem] {
        try ShelfSampleFiles.longNames.get().map(fileItem)
    }

    private static func fileItem(_ url: URL) -> ShelfItem {
        ShelfItem(kind: url.hasDirectoryPath ? .folder : url.pathExtension == "png" ? .image : .file,
                  path: url.path, displayName: url.lastPathComponent)
    }

    static func textSnippets() -> [ShelfItem] {
        let notes = [
            "Concept review\nCompare the ocean and pine palettes. Keep the wordmark readable at small sizes.\n\nPrepare a dark background version and check the contrast on the printed proof. Bring both directions to Friday's review.",
            "Finish the landing page wireframes, then prepare two identity concepts for review. Include a mobile layout, the signup form, and the empty states. We should compare the options together before sending the next round to production.",
            "Send the proof Friday"
        ]
        return notes.map {
            ShelfItem(kind: .text, displayName: DropImportCoordinator.displayName(forText: $0), text: $0)
        } + [
            ShelfItem(kind: .text, displayName: "Handoff notes",
                      text: "Include editable sources, color values, and a short guide to typography and spacing.\n\nExport the screen assets at both scales. Keep the print files in a separate folder and include the approved copy alongside the final artwork.")
        ]
    }
}
