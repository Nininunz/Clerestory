import Foundation
import XCTest
@testable import Clerestory

/// Age-based staging cleanup of TempFileService (review P1: promise shared staging is not cleaned in
/// callbacks,
/// handled by age-based cleanup at startup).
final class TempFileServiceTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClerestoryTests-TFS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The old PromiseStaging directory is deleted, and new ones unrelated entries are retained.
    func testCleanupStaleStagingDirectories_removesOnlyOldStaging() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let fileManager = FileManager.default

        let oldStaging = try service.createPromiseStagingDirectory()
        let newStaging = try service.createPromiseStagingDirectory()
        let materializedFile = directory.appendingPathComponent("\(UUID().uuidString)-photo.png")
        try "x".write(to: materializedFile, atomically: true, encoding: .utf8)
        // Set the modification time of oldStaging to two hours ago.
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try fileManager.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: oldStaging.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertFalse(fileManager.fileExists(atPath: oldStaging.path), "Expired staging should be cleaned up")
        XCTAssertTrue(fileManager.fileExists(atPath: newStaging.path), "New staging must be kept")
        XCTAssertTrue(fileManager.fileExists(atPath: materializedFile.path), "Non-staging entries are not affected")
    }

    /// The cleanup deletion scope does not exceed the hosted directory semantics: directories without the
    /// PromiseStaging prefix are left untouched.
    func testCleanupStaleStagingDirectories_ignoresNonStagingDirectories() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let other = directory.appendingPathComponent("SomeOtherDir", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: other.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testCleanupStaleStagingDirectories_preservesJournaledPayload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let staging = try service.createPromiseStagingDirectory()
        let payload = staging.appendingPathComponent("received.txt")
        try Data("retained".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)],
            ofItemAtPath: staging.path
        )

        service.cleanupStaleStagingDirectories(
            maxAge: 3600,
            keepingPaths: [payload.path]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testCreatePromiseStagingDirectory_usesCleanupCompatibleName() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)

        let staging = try service.createPromiseStagingDirectory()
        var isDirectory: ObjCBool = false

        XCTAssertTrue(staging.lastPathComponent.hasPrefix("PromiseStaging-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// Regular orphan cleanup must skip staging directories that may still have asynchronous writes; stale
    /// recovery is only handled by cleanupStaleStagingDirectories.
    func testCleanupOrphans_preservesPromiseStaging_butRemovesOrdinaryOrphan() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let staging = try service.createPromiseStagingDirectory()
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.txt")
        try "x".write(to: orphan, atomically: true, encoding: .utf8)

        service.cleanupOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCleanupOrphans_reportsRemovedItemsAndPreservesReferencedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let kept = try service.uniqueFileURL(suggestedName: "kept.bin")
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.bin")
        try Data(repeating: 1, count: 4_096).write(to: kept)
        try Data(repeating: 2, count: 8_192).write(to: orphan)

        XCTAssertGreaterThan(service.storageUsage(), 0)
        let result = service.cleanupOrphans(keepingPaths: [kept.path])

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
