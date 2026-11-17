import SwiftUI
@testable import OpenYoink

/// Runtime message formatters and models, without executing clipboard, file, or recovery actions.
@MainActor
enum ShelfFeedbackScenario {
    static var notices: [(id: String, label: String, notice: ShelfNoticeContent)] {
        var result = ShelfNoticeMessage.allCases.map {
            (id: "notice-" + $0.rawValue,
             label: "Notice / " + $0.rawValue.replacingOccurrences(of: "-", with: " ").capitalized,
             notice: $0.presentation)
        }
        result += [
            ("notice-copy-success", "Notice / Copied", ClipboardController.notice(for: .init(copiedCount: 3, skippedCount: 0, didWrite: true))),
            ("notice-copy-partial", "Notice / Copy skipped unavailable items", ClipboardController.notice(for: .init(copiedCount: 2, skippedCount: 1, didWrite: true))),
            ("notice-copy-failed", "Notice / Copy failed", ClipboardController.notice(for: .init(copiedCount: 0, skippedCount: 3, didWrite: false))),
            ("notice-paths-success", "Notice / Paths copied", ShelfActionRunner.pathCopyNotice(copied: 3, skipped: 0)),
            ("notice-paths-partial", "Notice / Paths skipped unavailable items", ShelfActionRunner.pathCopyNotice(copied: 2, skipped: 1)),
            ("notice-finder-success", "Notice / Shown in Finder", ShelfActionRunner.revealNotice(shown: 3, skipped: 0)),
            ("notice-finder-partial", "Notice / Finder skipped unavailable items", ShelfActionRunner.revealNotice(shown: 2, skipped: 1)),
            ("notice-share-success", "Notice / Shared", ShelfActionRunner.shareNotice(shared: 3, skipped: 0)),
            ("notice-share-partial", "Notice / Share skipped unavailable items", ShelfActionRunner.shareNotice(shared: 2, skipped: 1))
        ]
        return result
    }

    static func scenarios(context: PreviewContext) -> [ModuleScenario] {
        notices.map { notice in
            ModuleScenario(id: notice.id, label: notice.label) {
                let fixture = try ShelfScenarioFixture(.populated, notice: notice.notice)
                return ModuleScenarioContent(view: fixture.view(settings: context.settings()), dropTarget: fixture.dropTarget, notices: fixture.notices)
            }
        } + ShelfTransferSample.allCases.map { sample in
            ModuleScenario(id: "transfer-" + sample.rawValue,
                           label: "Transfer / " + sample.rawValue.replacingOccurrences(of: "-", with: " ").capitalized) {
                let fixture = try ShelfScenarioFixture(.populated, transfer: sample)
                return ModuleScenarioContent(view: fixture.view(settings: context.settings()), dropTarget: fixture.dropTarget, notices: fixture.notices)
            }
        }
    }
}

enum ShelfTransferSample: String, CaseIterable {
    case importPreparing = "import-preparing"
    case importReceiving = "import-receiving-batch"
    case importReceivingSingle = "import-receiving-single"
    case importReceivingUnknown = "import-receiving-unknown-count"
    case importReceivingWaiting = "import-receiving-waiting"
    case importFinalizing = "import-finalizing"
    case managedMove = "managed-move-receiving"
    case importDelivered = "import-added"
    case importPartial = "import-partial"
    case importReferences = "import-reference-fallback"
    case importWarnings = "import-added-with-warnings"
    case importUnsupported = "import-unsupported"
    case importSourceUnavailable = "import-source-unavailable"
    case importPromiseFailed = "import-promise-failed"
    case importMaterializationFailed = "import-materialization-failed"
    case importBookmarkFailed = "import-bookmark-failed"
    case importPersistenceFailed = "import-persistence-failed"
    case importCancelled = "import-cancelled"
    case exportPreparing = "export-preparing"
    case exportDelivering = "export-delivering-batch"
    case exportDeliveringSingle = "export-delivering-single"
    case exportAccepted = "export-destination-accepted"
    case exportDelivered = "export-delivered"
    case exportPartial = "export-partial"
    case exportFailed = "export-failed-select-item"
    case exportMissingOriginal = "export-missing-original-locate"
    case exportMissingManaged = "export-missing-managed-open-recovery"
    case exportCancelled = "export-cancelled"

    @MainActor
    func store(items: [ShelfItem]) -> TransferStore {
        let ids = Array(items.prefix(5).map(\.id))
        let first = items[0]
        func failure(_ reason: TransferFailureReason, _ action: RecoveryAction = .dragAgainFromSource,
                     _ impact: TransferFailureImpact = .itemNotAdded, item: ShelfItem? = nil) -> TransferFailure {
            TransferFailure(reason: reason, itemName: (item ?? first).displayName,
                            recoveryAction: action, impact: impact)
        }
        let direction: TransferDirection = rawValue.hasPrefix("export-") ? .exportFromShelf : .importIntoShelf
        var safety = direction == .exportFromShelf
            ? String(localized: "Items stay on the shelf if delivery fails.")
            : String(localized: "Original files remain unchanged.")
        var expected: Int? = 5
        var affected = ids
        let phase: TransferPhase
        switch self {
        case .importPreparing, .exportPreparing: phase = .preparing
        case .importReceiving, .exportDelivering: phase = .receiving(receivedCount: 2, expectedCount: 5)
        case .importReceivingSingle, .exportDeliveringSingle:
            affected = Array(ids.prefix(1)); expected = 1
            phase = .receiving(receivedCount: 0, expectedCount: 1)
        case .importReceivingUnknown:
            expected = nil
            phase = .receiving(receivedCount: 2, expectedCount: nil)
        case .importReceivingWaiting:
            expected = nil
            phase = .receiving(receivedCount: 0, expectedCount: nil)
        case .importFinalizing: phase = .finalizing
        case .managedMove:
            safety = String(localized: "Managed copies are protected while originals move to the Trash.")
            phase = .receiving(receivedCount: 2, expectedCount: 5)
        case .importDelivered, .exportDelivered: phase = .delivered
        case .exportAccepted: phase = .targetAccepted
        case .importPartial:
            phase = .partiallySucceeded(successCount: 3, failures: [
                failure(.sourceUnavailable, item: items[3]), failure(.promiseReceiveFailed, item: items[4])])
        case .importReferences:
            phase = .partiallySucceeded(successCount: 4, failures: [
                failure(.managedMoveFellBackToReference, .dismiss, .itemAddedWithWarning, item: items[4])])
        case .importWarnings:
            phase = .partiallySucceeded(successCount: 5, failures: [
                failure(.bookmarkFailed, .dragAgainFromSource, .itemAddedWithWarning)])
        case .importUnsupported: phase = .failed(failure(.unsupportedFormat))
        case .importSourceUnavailable: phase = .failed(failure(.sourceUnavailable))
        case .importPromiseFailed: phase = .failed(failure(.promiseReceiveFailed))
        case .importMaterializationFailed: phase = .failed(failure(.materializationFailed))
        case .importBookmarkFailed: phase = .failed(failure(.bookmarkFailed))
        case .importPersistenceFailed: phase = .failed(failure(.persistenceFailed, .openStorageRecovery))
        case .exportPartial:
            phase = .partiallySucceeded(successCount: 3, failures: [
                failure(.deliveryFailed, .retryByDraggingOut(itemID: items[3].id), item: items[3]),
                failure(.deliveryFailed, .retryByDraggingOut(itemID: items[4].id), item: items[4])])
        case .exportFailed: phase = .failed(failure(.deliveryFailed, .retryByDraggingOut(itemID: first.id)))
        case .exportMissingOriginal: phase = .failed(failure(.externalFileOffline, .locateExternalFile(itemID: first.id)))
        case .exportMissingManaged: phase = .failed(failure(.managedCopyMissing, .openStorageRecovery))
        case .importCancelled, .exportCancelled: phase = .cancelled
        }
        if direction == .importIntoShelf {
            switch phase {
            case .preparing, .failed, .cancelled, .targetAccepted: affected = []
            case .receiving(let count, _): affected = Array(ids.prefix(count))
            case .partiallySucceeded(let count, let failures):
                let referenceCount = failures.filter { $0.reason == .managedMoveFellBackToReference }.count
                affected = Array(ids.prefix(count + referenceCount))
            case .finalizing, .delivered: break
            }
        }
        return TransferStore.preview(phase: phase, direction: direction, itemIDs: affected,
                                     safetyMessage: safety, expectedCount: expected)
    }
}
