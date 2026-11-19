import Foundation

/// An independent, recoverable state for quick start exercises. Here, only a random token, stage, and
/// exercise card id are saved; the file path is always derived from `Tutorial/<session-id>/`, and the disk
/// JSON path is never trusted.
final class OnboardingSessionStore {
    struct Record: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case awaitingImport
            case awaitingExport
        }

        var sessionID: UUID
        var token: String
        var phase: Phase
        var tutorialItemID: UUID?
        var createdAt: Date
    }

    enum StoreError: Error, Equatable {
        case invalidSessionDirectory
    }

    static let tutorialFileName = "Clerestory Practice File.txt"
    private static let legacyTutorialFileName = "OpenYoink 练习文件.txt"

    let rootURL: URL
    private let fileManager: FileManager

    private var recordURL: URL { rootURL.appendingPathComponent("tutorial-session.json") }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
            ?? AppDirectories.applicationSupport().appendingPathComponent("Tutorial", isDirectory: true)
        self.fileManager = fileManager
    }

    func begin() throws -> Record {
        try discardAll()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let record = Record(sessionID: UUID(),
                            token: UUID().uuidString,
                            phase: .awaitingImport,
                            tutorialItemID: nil,
                            createdAt: Date())
        let directory = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let contents = String(localized: "This practice file was created by Clerestory. You can delete it safely.")
        try Data(contents.utf8).write(to: tutorialFileURL(for: record), options: .atomic)
        try save(record)
        return record
    }

    /// Return an incomplete session with valid structure and path. Damaged records return nil; the caller
    /// can use `discardAll()` to clear residual files entirely within the Tutorial root directory and
    /// restart.
    func load() -> Record? {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              !record.token.isEmpty,
              (record.phase == .awaitingImport || record.tutorialItemID != nil),
              (try? sessionDirectory(for: record.sessionID)) != nil else {
            return nil
        }
        return record
    }

    func markAwaitingExport(_ record: Record, tutorialItemID: UUID) throws -> Record {
        var updated = record
        updated.phase = .awaitingExport
        updated.tutorialItemID = tutorialItemID
        try save(updated)
        return updated
    }

    func tutorialFileURL(for record: Record) -> URL {
        let directory = rootURL
            .appendingPathComponent(record.sessionID.uuidString, isDirectory: true)
        let currentURL = directory.appendingPathComponent(Self.tutorialFileName, isDirectory: false)
        let legacyURL = directory.appendingPathComponent(Self.legacyTutorialFileName, isDirectory: false)
        if !fileManager.fileExists(atPath: currentURL.path), fileManager.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return currentURL
    }

    /// Delete a single session. Before deletion, strictly verify that the directory is a direct UUID
    /// subdirectory of the Tutorial root directory; any external path will be rejected.
    func discard(_ record: Record) throws {
        let directory = try sessionDirectory(for: record.sessionID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        if fileManager.fileExists(atPath: recordURL.path) {
            try fileManager.removeItem(at: recordURL)
        }
    }

    /// Clean up all tutorial remnants. The target is the fixed Tutorial root directory at construction
    /// time, not read from persistent data, so it will not expand to Application Support or user
    /// directories.
    func discardAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    func isTutorialFile(_ url: URL, for record: Record) -> Bool {
        url.standardizedFileURL == tutorialFileURL(for: record).standardizedFileURL
    }

    private func save(_ record: Record) throws {
        _ = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    private func sessionDirectory(for sessionID: UUID) throws -> URL {
        let root = rootURL.standardizedFileURL
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              UUID(uuidString: directory.lastPathComponent) == sessionID else {
            throw StoreError.invalidSessionDirectory
        }
        return directory
    }
}
