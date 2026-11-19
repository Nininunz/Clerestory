import XCTest
@testable import Clerestory

@MainActor
final class IslandTimerStoreTests: XCTestCase {
    private func suite() throws -> (UserDefaults, String) {
        let name = "IslandTimerTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testPauseResumeUsesRemainingDuration() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 600)
        now = now.addingTimeInterval(125)
        timer.pause()
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        now = now.addingTimeInterval(500)
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        timer.resume()
        XCTAssertEqual(timer.remaining(), 475, accuracy: 0.001)
        timer.stop()
    }

    func testRunningTimerRestoresAcrossLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 2_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 300)
        first.stop()
        now = now.addingTimeInterval(40)
        let restored = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restored.remaining(), 260, accuracy: 0.001)
        restored.stop()
    }

    func testElapsedTimerRestoresAsFinished() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 3_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 10)
        first.stop()
        now = now.addingTimeInterval(11)
        let restored = IslandTimerStore(defaults: defaults, now: { now })
        guard case .finished = restored.state else {
            return XCTFail("Expected finished timer after elapsed end date")
        }
    }

    func testSystemTimeJumpFinishesWithoutPollingLoop() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 4_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 60)
        timer.stop()
        now = now.addingTimeInterval(120)
        timer.updateForCurrentTime()
        guard case .finished = timer.state else {
            return XCTFail("Expected clock jump to finish timer")
        }
    }

    func testTickRefreshesFormattedTimeAndProgress() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 5_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.start(duration: 60)
        let initialTick = timer.tick

        now = now.addingTimeInterval(1)
        timer.updateForCurrentTime()

        XCTAssertGreaterThan(timer.tick, initialTick)
        XCTAssertEqual(timer.formattedRemaining, "00:59")
        XCTAssertEqual(timer.progress, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(timer.remainingFraction, 59.0 / 60.0, accuracy: 0.000_001)
        timer.stop()
    }

    func testNotchTimerOmitsSecondsOnlyForThreeDigitMinutes() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 5_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })

        timer.start(duration: 105 * 60 + 47)
        XCTAssertEqual(timer.formattedRemaining, "105:47")
        XCTAssertEqual(timer.notchRemaining, "105m")

        timer.start(duration: 99 * 60 + 59)
        XCTAssertEqual(timer.notchRemaining, "99:59")
        timer.stop()
    }

    func testFlowModeAndGoalPersistAcrossLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(first.mode, .focus)
        first.selectMode(.longBreak)
        first.setGoal("Read the architecture notes")

        let restored = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .longBreak)
        XCTAssertEqual(restored.mode.defaultMinutes, 15)
        XCTAssertEqual(restored.goal, "Read the architecture notes")
    }

    func testRunningTimerKeepsItsSelectedMode() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let timer = IslandTimerStore(defaults: defaults)
        timer.selectMode(.shortBreak)
        timer.start(duration: 300)
        timer.selectMode(.focus)

        XCTAssertEqual(timer.mode, .shortBreak)
        timer.stop()
    }

    func testFocusGoalIsUsedForTheRunningStatus() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let messages = IslandMessageCenter.forTesting()
        messages.moduleDidStart(.timer)
        let timer = IslandTimerStore(defaults: defaults)
        timer.messenger = messages.messenger(for: .timer)
        timer.setGoal("Finish the timer redesign")
        timer.start(duration: 60)

        let status = try XCTUnwrap(messages.topStatus(for: .timer))
        XCTAssertEqual(status.key, "running")
        XCTAssertEqual(status.title, "Finish the timer redesign")
        XCTAssertEqual(status.detail, "01:00")
        XCTAssertEqual(status.systemImage, "scope")
        XCTAssertEqual(status.tone, .neutral)
        timer.pause()
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["running"], "Paused keeps the running status")
        timer.reset()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty, "Idle clears it")
    }

    func testFinishingSetsTheFinishedStatusAndCallsOnDidFinishOnce() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(announcer: .recording(into: spoken))
        messages.moduleDidStart(.timer)
        var now = Date(timeIntervalSince1970: 1_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.messenger = messages.messenger(for: .timer)
        var finishCount = 0
        timer.onDidFinish = { finishCount += 1 }
        timer.start(duration: 60)
        XCTAssertNil(messages.currentNotice, "A running timer is neutral and never announces")

        now = now.addingTimeInterval(61)
        timer.updateForCurrentTime()
        timer.updateForCurrentTime()
        timer.start()

        XCTAssertEqual(finishCount, 1)
        let status = try XCTUnwrap(messages.topStatus(for: .timer))
        XCTAssertEqual(status.key, "finished")
        XCTAssertEqual(status.title, "Timer finished")
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(messages.statuses(for: .timer).count, 1, "Finished replaces running")
        XCTAssertEqual(spoken.messages, ["Timer finished. Show is available."], "Announced once when raised")
        XCTAssertEqual(messages.currentNotice?.raisedStatusKey, "finished")

        timer.acknowledgeFinished()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        XCTAssertNil(messages.currentNotice, "The pill goes when the status clears first")
    }

    func testTimerThatFinishedWhileQuitOpensThePanelOnceAtLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_000)
        let beforeQuit = IslandTimerStore(defaults: defaults, now: { now })
        beforeQuit.start(duration: 60)
        beforeQuit.stop()

        now = now.addingTimeInterval(300)
        let messages = IslandMessageCenter.forTesting()
        messages.moduleDidStart(.timer)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(timer.state, .finished(originalDuration: 60), "Restore completes the expired timer")
        timer.messenger = messages.messenger(for: .timer)
        var finishCount = 0
        timer.onDidFinish = { finishCount += 1 }

        timer.start()
        XCTAssertEqual(finishCount, 1, "The first start opens the Panel once")
        XCTAssertEqual(messages.topStatus(for: .timer)?.key, "finished")

        timer.stop()
        timer.start()
        XCTAssertEqual(finishCount, 1, "A later stop and start while finished does not reopen it")
        timer.stop()
    }

    func testFinishedPillIsWithdrawnWhenThePanelShowsTimer() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(announcer: .recording(into: spoken))
        messages.moduleDidStart(.timer)
        var now = Date(timeIntervalSince1970: 1_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.messenger = messages.messenger(for: .timer)
        // ShelfWindowController opens the Panel on Timer from onDidFinish.
        timer.onDidFinish = { messages.setShownModule(.timer, othersWait: true) }
        timer.start(duration: 60)

        now = now.addingTimeInterval(60)
        timer.updateForCurrentTime()

        XCTAssertEqual(messages.topStatus(for: .timer)?.key, "finished")
        XCTAssertEqual(spoken.messages, ["Timer finished. Show is available."], "VoiceOver still speaks it")
        XCTAssertNil(messages.currentNotice, "The open Panel already shows Timer, so no pill")
    }

    func testGoalLengthIsBoundedBeforePersistence() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let timer = IslandTimerStore(defaults: defaults)
        timer.setGoal(String(repeating: "x", count: 120))

        XCTAssertEqual(timer.goal.count, 80)
        let restored = IslandTimerStore(defaults: defaults)
        XCTAssertEqual(restored.goal.count, 80)
    }

    func testCompletedFocusSessionPersistsHistoryAndGoal() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 10_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })
        timer.setGoal("Write the release notes")
        timer.start(duration: 60)

        now = now.addingTimeInterval(60)
        timer.updateForCurrentTime()

        let session = try XCTUnwrap(timer.sessions.first)
        XCTAssertEqual(timer.sessions.count, 1)
        XCTAssertEqual(session.duration, 60, accuracy: 0.001)
        XCTAssertEqual(session.completedAt, Date(timeIntervalSince1970: 10_060))
        XCTAssertEqual(session.goal, "Write the release notes")

        let restored = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restored.sessions, timer.sessions)
    }

    func testBreakAndResetDoNotCreateFocusHistory() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 20_000)
        let timer = IslandTimerStore(defaults: defaults, now: { now })

        timer.selectMode(.shortBreak)
        timer.start(duration: 1)
        now = now.addingTimeInterval(1)
        timer.updateForCurrentTime()
        XCTAssertTrue(timer.sessions.isEmpty)

        timer.acknowledgeFinished()
        timer.selectMode(.focus)
        timer.start(duration: 60)
        timer.reset()
        XCTAssertTrue(timer.sessions.isEmpty)
    }

    func testElapsedRestoreRecordsFocusSessionExactlyOnce() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 30_000)
        let first = IslandTimerStore(defaults: defaults, now: { now })
        first.start(duration: 60)
        first.stop()

        now = now.addingTimeInterval(61)
        let restoredOnce = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restoredOnce.sessions.count, 1)
        let restoredAgain = IslandTimerStore(defaults: defaults, now: { now })
        XCTAssertEqual(restoredAgain.sessions.count, 1)
        XCTAssertEqual(restoredAgain.sessions.first?.id,
                       restoredOnce.sessions.first?.id)
    }
}
