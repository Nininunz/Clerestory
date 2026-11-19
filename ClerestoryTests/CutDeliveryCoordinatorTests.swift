import Foundation
import XCTest
@testable import Clerestory

/// DeliveryCoordinator's delivery confirmation state machine: normal direct drag-out is confirmed by
/// session result; hosted cut items require 'target accepts × promise delivery'. Override reverse, cancel,
/// failure, stack, and lease.
@MainActor
final class DeliveryCoordinatorTests: XCTestCase {
    @MainActor
    private struct Context {
        let store: ShelfStore
        let recents: RecentItemsService
        let tempFileService: TempFileService
        let transferStore = TransferStore()
        let coordinator: DeliveryCoordinator
        var temporaryURLs: [URL] = []

        init(items: [ShelfItem] = []) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClerestoryTests-CutDelivery-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            recents = RecentItemsService(directoryURL: root)
            store = ShelfStore(items: items)
            coordinator = DeliveryCoordinator(store: store,
                                              recents: recents,
                                              tempFileService: tempFileService,
                                              transferStore: transferStore)
            temporaryURLs.append(root)
        }

        func cleanup() {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext() -> Context { Context() }

    /// Create a real file in managed storage and an isCut ShelfItem that points to it.
    private func makeCutItem(in context: inout Context, name: String = "cut-me.txt") throws -> ShelfItem {
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: name)
        try "managed content".write(to: managedURL, atomically: true, encoding: .utf8)
        return ShelfItem(kind: .file,
                         path: managedURL.path,
                         displayName: name,
                         isCut: true)
    }

    private func contents(for items: [ShelfItem]) -> DragOutContents {
        DragOutContents(items: items, topLevelIDs: Set(items.map(\.id)))
    }

    private func beginSession(_ context: Context, items: [ShelfItem]) -> UUID {
        let id = UUID()
        context.coordinator.noteSessionBegan(id: id, contents: contents(for: items))
        return id
    }

    // MARK: - Drag session count

    /// A drag that never starts an AppKit session (no pasteboard writer could
    /// be built) must not leave the transfer strip hidden for good.
    func testUnstartedDragSessionDoesNotHideTransferStrip() {
        let context = makeContext()
        defer { context.cleanup() }
        let item = ShelfItem(kind: .text, displayName: "empty")
        let sessionID = beginSession(context, items: [item])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: false)
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 0)

        context.coordinator.noteDragSessionStarted()
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 1)
        context.coordinator.noteDragSessionEnded()
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 0)
    }

    // MARK: - Delivery loop

    /// Normal timeline: session successfully ends → promise write completes → remove from shelf + delete
    /// custody file + record history.
    func testDeliveryAfterSuccessfulSession_finalizesItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = try XCTUnwrap(context.temporaryURLs.first).appendingPathComponent("delivered.txt")
        let source = try XCTUnwrap(item.fileURL)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertNotNil(context.store.item(withID: item.id), "Do not remove before delivery is confirmed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FilePromiseProvider.writeCopy(
            of: .init(sourceURL: source, bookmark: item.bookmark,
                      suggestedName: item.displayName, promisedFileType: "public.plain-text"),
            to: destination,
            bookmarkService: BookmarkService()
        )
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)

        XCTAssertNil(context.store.item(withID: item.id), "The item must leave the shelf after delivery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "The managed copy must be deleted after delivery")
        XCTAssertEqual(try Data(contentsOf: destination), Data("managed content".utf8))
        let entry = try XCTUnwrap(context.recents.entries.first)
        XCTAssertEqual(entry.displayName, item.displayName)
        XCTAssertEqual(entry.path, destination.path, "Recents record the delivery destination path (the managed copy is deleted)")
    }

    /// Reverse timeline: promise write completes before session ends (for small files) → finalize upon
    /// session successful end.
    func testDeliveryBeforeSessionEnd_finalizesOnSessionEnd() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)
        XCTAssertNotNil(context.store.item(withID: item.id), "Do not remove before the session ends successfully")
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertEqual(context.recents.entries.first?.path, destination.path)
    }

    /// Cancel (operation == []): item and custody file are retained, waiting for state clearance.
    func testCancelledSession_keepsItemAndManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: false)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertTrue(context.recents.entries.isEmpty)
        // Defense: canceling later undeliverables from unknown sources does not change any state.
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/x.txt"))
        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
    }

    /// Delivery failed: item is retained with custody file (retryable), status bar shows real failure.
    func testDeliveryFailure_keepsItemAndShowsTransferFailure() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        let source = try XCTUnwrap(item.fileURL)
        let destination = try XCTUnwrap(context.temporaryURLs.first).appendingPathComponent("already-exists.txt")
        let existingContents = Data("existing destination contents".utf8)
        try existingContents.write(to: destination)
        XCTAssertThrowsError(try FilePromiseProvider.writeCopy(
            of: .init(sourceURL: source, bookmark: item.bookmark,
                      suggestedName: item.displayName, promisedFileType: "public.plain-text"),
            to: destination,
            bookmarkService: BookmarkService()
        ))
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertEqual(try Data(contentsOf: source), Data("managed content".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), existingContents)
        if case .failed(let failure) = context.transferStore.currentTask?.phase {
            XCTAssertEqual(failure.reason, .deliveryFailed)
            XCTAssertEqual(failure.recoveryAction, .retryByDraggingOut(itemID: item.id))
        } else {
            XCTFail("A failed delivery must enter the failed state")
        }
        XCTAssertTrue(context.recents.entries.isEmpty)
    }

    /// Cut item in stack subitem: removed from stack after delivery (subitem dragged out of topLevelIDs
    /// becomes empty).
    func testCutChildInStack_removedFromStackOnDelivery() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let cutChild = try makeCutItem(in: &context, name: "child.txt")
        let sibling = ShelfItem(kind: .file, path: "/tmp/sibling.txt", displayName: "sibling.txt")
        let stack = ShelfItem(kind: .stack, displayName: "child.txt", children: [cutChild, sibling])
        context.store.add(stack)
        // Floating subitem dragged out: topLevelIDs becomes empty (top-level stack itself is not removed).
        let childContents = DragOutContents(items: [cutChild], topLevelIDs: [])
        let sessionID = UUID()
        context.coordinator.noteSessionBegan(id: sessionID, contents: childContents)

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: cutChild.id,
                                          destination: URL(fileURLWithPath: "/tmp/out-child.txt"))

        XCTAssertNil(context.store.item(withID: stack.id), "The stack dissolves automatically when 1 child remains")
        let survivor = try XCTUnwrap(context.store.items.first)
        XCTAssertEqual(survivor.id, sibling.id, "After the stack dissolves, the surviving child stays in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutChild.fileURL!.path))
    }

    /// User manually removed the item before delivery arrives: custody file is still deleted, no crash,
    /// history is recorded.
    func testDeliveryAfterManualRemoval_stillDeletesManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.store.remove(ids: [item.id]) // User manually removed
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/out.txt"))

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "The item snapshot drives finalization: delete the managed copy even if the store no longer has it")
        XCTAssertEqual(context.recents.entries.first?.displayName, item.displayName)
    }

    /// When an ordinary file hasn't requested a promise, it can only express 'target has accepted'.
    func testOrdinaryDirectRepresentationReportsTargetAccepted() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let normal = ShelfItem(kind: .file, path: "/tmp/normal.txt", displayName: "normal.txt")
        context.store.add(normal)
        let sessionID = beginSession(context, items: [normal])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNotNil(context.store.item(withID: normal.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
        XCTAssertTrue(context.recents.entries.isEmpty, "History for regular items is recorded by the DragSessionController policy path")
    }

    /// After using the `.remove` strategy to remove an ordinary materialized item, already accepted direct
    /// drag sessions still protect the source file,
    /// preventing users from cleaning up the only copy from the 'Storage' page before the target has
    /// completed reading.
    func testAcceptedDirectMaterializedItemProtectsRuntimeLeaseAfterRemoval() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: "kept.txt")
        try "only copy".write(to: managedURL, atomically: true, encoding: .utf8)
        let item = ShelfItem(kind: .file,
                             path: managedURL.path,
                             displayName: "kept.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertTrue(context.coordinator.protectedMaterializedPaths.contains(managedURL.path))
    }

    /// Ordinary items no longer carry a file promise; even if an unknown-source late callback is received,
    /// they cannot
    /// reinsert or fabricate a failed state for items already removed by the user's policy.
    func testDirectItemIgnoresSpuriousPromiseCallbacks() {
        let context = makeContext()
        defer { context.cleanup() }
        let item = ShelfItem(kind: .file, path: "/tmp/direct.txt", displayName: "direct.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.notePromiseRequested(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/unexpected.txt"))
        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
    }
}
