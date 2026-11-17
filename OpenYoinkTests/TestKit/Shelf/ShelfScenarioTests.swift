import SwiftUI
import AppKit
import CryptoKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfScenarioTests: XCTestCase {
    func testNoticeSemanticsAndRecoveryActions() {
        XCTAssertEqual(ShelfNoticeMessage.reconnected.presentation.kind, .success)
        XCTAssertEqual(ShelfNoticeMessage.clipboardEmpty.presentation.kind, .info)
        XCTAssertEqual(ShelfNoticeMessage.importFailed.presentation.kind, .error)
        for message in [ShelfNoticeMessage.moveAwaitingSave, .receivedAwaitingRecovery,
                        .moveRecoveryNeedsAttention, .partialMoveRecoveryNeedsAttention,
                        .interruptedImportRecovered, .importRecoveryNeedsAttention] {
            XCTAssertEqual(message.presentation.kind, .warning)
            XCTAssertEqual(message.presentation.recoveryAction, .openStorageRecovery)
            XCTAssertEqual(message.presentation.details, message.text)
        }
        XCTAssertEqual(ClipboardController.notice(for: .init(copiedCount: 3, skippedCount: 0, didWrite: true)).kind, .success)
        XCTAssertEqual(ClipboardController.notice(for: .init(copiedCount: 2, skippedCount: 1, didWrite: true)).kind, .warning)
        XCTAssertEqual(ClipboardController.notice(for: .init(copiedCount: 0, skippedCount: 3, didWrite: false)).kind, .error)
        for make in [ShelfActionRunner.pathCopyNotice, ShelfActionRunner.revealNotice, ShelfActionRunner.shareNotice] {
            XCTAssertEqual(make(3, 0).kind, .success)
            XCTAssertEqual(make(2, 1).kind, .warning)
        }
    }

    func testGeneratedSamplesContainReadableDocumentsAndImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try ShelfSampleFiles.create(in: root)
        XCTAssertEqual(urls.count, 6)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        for url in urls where url.pathExtension == "png" {
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertGreaterThanOrEqual(image.size.width, 1200)
            XCTAssertGreaterThanOrEqual(image.size.height, 800)
        }
        let brief = try XCTUnwrap(urls.first { $0.pathExtension == "rtf" })
        let document = try NSAttributedString(url: brief, options: [:], documentAttributes: nil)
        XCTAssertTrue(document.string.contains("Project brief"))
        let csv = try XCTUnwrap(urls.first { $0.pathExtension == "csv" })
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertEqual(csvText.split(separator: "\n").count, 34)
        XCTAssertTrue(csvText.contains("All phases"))
        XCTAssertGreaterThan(document.string.split(whereSeparator: \.isWhitespace).count, 500)
        let folder = try XCTUnwrap(urls.first { $0.hasDirectoryPath })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Palette.txt").path))
    }

    func testLargeGridAndLongNamesUseDistinctRealFiles() throws {
        for (scenario, count) in [(ShelfScenario.manyItems, 40), (.longNames, 8)] {
            let fixture = try ShelfScenarioFixture(scenario)
            let items = fixture.store.items
            XCTAssertEqual(items.count, count)
            let urls = try items.map { try XCTUnwrap($0.fileURL) }
            XCTAssertEqual(Set(urls).count, count)
            XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(items.allSatisfy { $0.kind != .text && $0.displayName == $0.fileURL?.lastPathComponent })
            XCTAssertTrue(items.contains { $0.kind == .image })
            XCTAssertTrue(items.contains { $0.kind == .folder })
            if scenario == .longNames { XCTAssertTrue(items.allSatisfy { $0.displayName.count > 90 }) }
        }
        let snippets = try ShelfScenarioFixture(.textSnippets)
        XCTAssertTrue(snippets.store.items.allSatisfy { $0.kind == .text && $0.fileURL == nil })
    }

    func testGeneratedCollectionsDoNotReuseFileContents() throws {
        let urls = try ShelfSampleFiles.manyItems.get() + ShelfSampleFiles.longNames.get()
        var payloads = Set<Data>()
        for url in urls {
            let files = url.hasDirectoryPath
                ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                : [url]
            var bytes = Data()
            for file in files { bytes.append(try Data(contentsOf: file)) }
            XCTAssertTrue(payloads.insert(Data(SHA256.hash(data: bytes))).inserted,
                          "Repeated contents: \(url.lastPathComponent)")
        }
        XCTAssertEqual(payloads.count, 48)
    }

    func testDragScenariosSupplySurfaceStateAndCorrectOutlineColor() throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        for (scenario, expectedColor) in [(ShelfScenario.fileDrag, Color.blue), (.duplicate, Color.red)] {
            let content = try scenario.scenario(context: context).makeView()
            let target = try XCTUnwrap(content.dropTarget)
            let outline = IslandDropOutline(progress: 1, collapsedSize: CGSize(width: 290, height: 38),
                                            attachedToScreenTop: true, state: target)
            XCTAssertTrue(outline.isVisible)
            XCTAssertEqual(outline.tint, expectedColor)
            target.isTargeted = false
            XCTAssertFalse(outline.isVisible)
        }
        let idle = try ShelfScenario.populated.scenario(context: context).makeView()
        XCTAssertFalse(try XCTUnwrap(idle.dropTarget).isTargeted)
    }

    func testFixturesAreIndependentAndSelectionDoesNotLeak() throws {
        let selected = try ShelfScenarioFixture(.selected)
        let fresh = try ShelfScenarioFixture(.populated)
        XCTAssertEqual(selected.store.selection.count, 2)
        XCTAssertTrue(fresh.store.selection.isEmpty)
        XCTAssertTrue(Set(selected.store.items.map(\.id)).isDisjoint(with: fresh.store.items.map(\.id)))
    }

    func testStackSelectionCanBeClearedWithoutChangingParentSelection() throws {
        let fixture = try ShelfScenarioFixture(.stackSelection)
        let parent = try XCTUnwrap(fixture.interaction.expandedStackID)
        XCTAssertEqual(fixture.interaction.childSelection.count, 2)
        XCTAssertEqual(fixture.store.selection, [parent])
        XCTAssertTrue(fixture.interaction.clearActiveSelection(in: fixture.store))
        XCTAssertTrue(fixture.interaction.childSelection.isEmpty)
        XCTAssertEqual(fixture.store.selection, [parent])
        XCTAssertEqual(fixture.interaction.expandedStackID, parent)
    }

    func testDuplicateStateAndSearchDoNotMutateContents() throws {
        let duplicate = try ShelfScenarioFixture(.duplicate)
        XCTAssertTrue(duplicate.dropTarget.isTargeted)
        XCTAssertTrue(duplicate.dropTarget.hasDuplicateFiles)
        XCTAssertFalse(duplicate.dropTarget.isReordering)
        XCTAssertEqual(duplicate.store.items.count, 7)
        let search = try ShelfScenarioFixture(.noResults)
        XCTAssertTrue(search.store.visibleItems.isEmpty)
        XCTAssertEqual(search.store.items.count, 7)
        search.store.searchQuery = ""
        XCTAssertEqual(search.store.visibleItems.count, 7)
    }

    func testFeedbackCatalogCoversNoticesAndTransferStates() throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let ids = Set(ShelfScenario.catalog(context: context).map(\.id))
        for notice in ShelfNoticeMessage.allCases {
            XCTAssertTrue(ids.contains("notice-" + notice.rawValue))
            let fixture = try ShelfScenarioFixture(.populated, notice: notice.presentation)
            XCTAssertEqual(fixture.notices.message, notice.text)
        }
        for sample in ShelfTransferSample.allCases {
            XCTAssertTrue(ids.contains("transfer-" + sample.rawValue))
            let fixture = try ShelfScenarioFixture(.populated, transfer: sample)
            let task = try XCTUnwrap(fixture.transfers.currentTask)
            XCTAssertFalse(task.safetyMessage.isEmpty)
            XCTAssertTrue(Set(task.itemIDs).isSubset(of: Set(fixture.store.items.map(\.id))))
            fixture.transfers.dismiss(taskID: task.id)
            XCTAssertFalse(fixture.transfers.hasVisibleActivity)
        }
        XCTAssertTrue(ids.contains("drag-move-hint"))
        XCTAssertTrue(ids.contains("drag-reorder-hint"))
    }

    func testFeedbackPreviewsKeepRuntimeRecoveryActionsAndCardStatuses() throws {
        let checks: [(ShelfTransferSample, String)] = [
            (.exportMissingOriginal, "Locate…"), (.exportMissingManaged, "Open Recovery"),
            (.exportFailed, "Select Item"), (.importPersistenceFailed, "Open Recovery")
        ]
        for (sample, title) in checks {
            let fixture = try ShelfScenarioFixture(.populated, transfer: sample)
            let task = try XCTUnwrap(fixture.transfers.currentTask)
            XCTAssertEqual(ShelfActivityStrip.primaryRecovery(for: task)?.title, title)
        }
        let receiving = try ShelfScenarioFixture(.populated, transfer: .importReceiving)
        XCTAssertEqual(receiving.transfers.currentTask?.itemIDs.count, 2)
        XCTAssertEqual(receiving.transfers.accessibilityStatus(for: receiving.store.items[0].id), .receiving)
        XCTAssertNil(receiving.transfers.accessibilityStatus(for: receiving.store.items[2].id))
        let accepted = try ShelfScenarioFixture(.populated, transfer: .exportAccepted)
        XCTAssertEqual(accepted.transfers.accessibilityStatus(for: accepted.store.items[0].id), .destinationAccepted)
        let failed = try ShelfScenarioFixture(.populated, transfer: .exportFailed)
        XCTAssertEqual(failed.transfers.accessibilityStatus(for: failed.store.items[0].id), .deliveryFailed)
        let partial = try ShelfScenarioFixture(.populated, transfer: .exportPartial)
        XCTAssertEqual(partial.transfers.accessibilityStatus(for: partial.store.items[0].id), .delivered)
        XCTAssertEqual(partial.transfers.accessibilityStatus(for: partial.store.items[3].id), .deliveryFailed)
        let move = try ShelfScenarioFixture(.moveDrag)
        XCTAssertEqual(move.dropTarget.mode, .move)
        XCTAssertTrue(move.dropTarget.isTargeted)
        let reorder = try ShelfScenarioFixture(.reorderDrag)
        XCTAssertTrue(reorder.dropTarget.isReordering)
        XCTAssertTrue(reorder.dropTarget.isTargeted)
    }

    func testPreviewFeedbackDoesNotExpireButRuntimeNoticesStillDo() async throws {
        let preview = try ShelfScenarioFixture(.populated, notice: ShelfNoticeMessage.removed.presentation,
                                               transfer: .importDelivered)
        let runtime = ShelfNoticeModel()
        runtime.show(.removed)
        try await Task.sleep(for: .seconds(ShelfNoticeModel.displayDuration + 0.3))
        XCTAssertNil(runtime.message)
        XCTAssertEqual(preview.notices.message, ShelfNoticeMessage.removed.text)
        XCTAssertEqual(preview.transfers.currentTask?.phase, .delivered)
    }

    func testScenarioCatalogHasUniqueStableIDs() {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let scenarios = ShelfScenario.catalog(context: context)
        XCTAssertEqual(Set(scenarios.map(\.id)).count, scenarios.count)
        XCTAssertFalse(scenarios.contains { $0.id == "expanded-stack" })
        XCTAssertFalse(scenarios.contains { $0.id == "stack-selection" })
        XCTAssertTrue(scenarios.contains { $0.id == "duplicate" })
    }
}
