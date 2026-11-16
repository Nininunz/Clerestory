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

    static func longNames() -> [ShelfItem] {
        (1...8).map { ShelfItem(kind: .text,
            displayName: "A very long project document title with version numbers and extra detail \($0).txt",
            text: "A longer excerpt to check the text preview and filename truncation.") }
    }
}
