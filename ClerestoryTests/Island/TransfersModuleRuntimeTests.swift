import XCTest
@testable import Clerestory

@MainActor
final class TransfersModuleRuntimeTests: XCTestCase {
    func testPhaseChangeWhileVisibleUpdatesTheStatusAndFailurePostsNoNotice() async throws {
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(announcer: .recording(into: spoken))
        messages.moduleDidStart(.transfers)
        let transfers = TransferStore()
        let runtime = TransfersModuleRuntime(transferStore: transfers,
                                             messenger: messages.messenger(for: .transfers))
        runtime.start()
        XCTAssertTrue(messages.statuses(for: .transfers).isEmpty)

        let taskID = transfers.beginImport(expectedCount: 1)
        await settle()
        var status = try XCTUnwrap(messages.topStatus(for: .transfers))
        XCTAssertEqual(status.key, "transfer")
        XCTAssertEqual(status.tone, .progress)
        XCTAssertEqual(status.systemImage, "arrow.up.arrow.down")

        // The strip stays visible, so only the phase changes.
        transfers.recordFailure(taskID: taskID, failure: TransferFailure(reason: .unsupportedFormat,
                                                                         recoveryAction: .dragAgainFromSource))
        XCTAssertTrue(transfers.hasVisibleActivity)
        await settle()
        status = try XCTUnwrap(messages.topStatus(for: .transfers))
        XCTAssertEqual(status.title, "Transfer failed")
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(status.systemImage, "exclamationmark.octagon.fill")
        XCTAssertNil(messages.currentNotice, "The strip alone presents the failure")
        XCTAssertTrue(spoken.messages.isEmpty, "The transfer planner speaks, not the status")

        transfers.dismiss(taskID: taskID)
        await settle()
        XCTAssertTrue(messages.statuses(for: .transfers).isEmpty, "No task clears it")
        runtime.stop()
    }

    func testRuntimeKeepsUpdatingAfterStopAndStart() async throws {
        let messages = IslandMessageCenter.forTesting()
        let transfers = TransferStore()
        let runtime = TransfersModuleRuntime(transferStore: transfers,
                                             messenger: messages.messenger(for: .transfers))
        messages.moduleDidStart(.transfers)
        runtime.start()
        let taskID = transfers.beginImport(expectedCount: 2)
        await settle()
        runtime.stop()
        messages.moduleDidStop(.transfers)
        XCTAssertTrue(messages.statuses(for: .transfers).isEmpty)

        messages.moduleDidStart(.transfers)
        runtime.start()
        XCTAssertEqual(messages.topStatus(for: .transfers)?.tone, .progress, "Start sets the current task's status")
        transfers.recordFailure(taskID: taskID, failure: TransferFailure(reason: .unsupportedFormat,
                                                                         recoveryAction: .dragAgainFromSource))
        transfers.recordFailure(taskID: taskID, failure: TransferFailure(reason: .unsupportedFormat,
                                                                         recoveryAction: .dragAgainFromSource))
        await settle()
        XCTAssertEqual(messages.topStatus(for: .transfers)?.tone, .warning)
        runtime.stop()
    }

    /// Lets the runtime's observation re-arm and read the new task.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
