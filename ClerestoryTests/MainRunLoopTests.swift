import AppKit
import XCTest
@testable import Clerestory

@MainActor
final class MainRunLoopTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var value = false }

    /// Reproduces #123: AppKit waits for a quit reply in a nested run loop inside a block that
    /// is already running on the main queue. Work sent through the run loop still runs; a
    /// main-actor task does not until the block returns.
    func testRunsWhileAMainQueueBlockWaitsInANestedRunLoop() {
        let finished = expectation(description: "main-queue block finished")
        let onRunLoop = Flag()
        let onActor = Flag()
        DispatchQueue.main.async {
            Task { @MainActor in onActor.value = true }
            Task.detached { MainRunLoop.perform { onRunLoop.value = true } }
            let deadline = Date().addingTimeInterval(3)
            while !onRunLoop.value, Date() < deadline {
                RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(onRunLoop.value)
            XCTAssertFalse(onActor.value, "A main-actor task can't run until this main-queue block returns")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
}
