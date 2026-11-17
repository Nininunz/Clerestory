#if DEBUG
import AppKit

/// Two synthetic documents for Quick Look keyboard tests in the isolated store.
@MainActor
final class ShelfUITestFixture {
    let files: [URL]

    init() throws {
        let directory = AppDirectories.applicationSupport().appendingPathComponent("UITestSources")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = ["Northline brief.txt", "Release checklist.txt"].map { directory.appendingPathComponent($0) }
        for (index, file) in files.enumerated() {
            let content = "\(file.deletingPathExtension().lastPathComponent)\n\n"
                + (1...24).map { "Section \($0): \(index == 0 ? "Review the design and export requirements." : "Verify the release and delivery steps.")" }.joined(separator: "\n")
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func seed(_ store: ShelfStore) {
        store.add(contentsOf: files.enumerated().map { index, file in
            ShelfItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                      kind: .file, path: file.path, displayName: file.lastPathComponent)
        })
    }
}
#endif
