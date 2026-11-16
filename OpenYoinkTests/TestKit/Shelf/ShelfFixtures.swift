import Foundation
@testable import OpenYoink

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
        [
            ("Concept review", "Compare the ocean and pine palettes. Keep the wordmark readable at small sizes."),
            ("Next steps", "Finish the landing page wireframes, then prepare two identity concepts for review."),
            ("Print checklist", "Confirm trim size, add bleed, and export a proof before sending the final artwork."),
            ("Handoff notes", "Include editable sources, color values, and a short guide to typography and spacing.")
        ].map { ShelfItem(kind: .text, displayName: $0.0, text: $0.1) }
    }
}
