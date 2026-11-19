import XCTest
@testable import Clerestory

@MainActor
final class IslandMessageCenterTests: XCTestCase {
    private var clock: ManualMessageClock!
    private var spoken: AnnouncementRecorder!

    override func setUp() async throws {
        clock = ManualMessageClock()
        spoken = AnnouncementRecorder()
    }

    private func makeCenter(running: Bool = true) -> IslandMessageCenter {
        let center = IslandMessageCenter(clock: clock, announcer: .recording(into: spoken))
        center.setNoticeClockRunning(running)
        return center
    }

    private func plain(_ key: String, _ title: String? = nil, tone: IslandNotice.Tone = .info,
                       duration: TimeInterval? = nil) -> IslandNotice {
        IslandNotice(key: key, title: title ?? key, tone: tone, duration: duration)
    }

    private func actionable(_ key: String) -> IslandNotice {
        IslandNotice(key: key, title: key, action: .openModule(.timer))
    }

    // MARK: - Basics

    func testFirstNoticeShowsAndOtherModulesQueueBehindIt() throws {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.alreadyOnShelf)
        let first = try XCTUnwrap(center.currentNotice)
        XCTAssertEqual(first.moduleID, .shelf)
        XCTAssertEqual(first.notice, ShelfNotice.alreadyOnShelf.notice)
        XCTAssertEqual(first.revision, center.noticeRevision(for: .shelf))

        center.messenger(for: .battery).post(plain("power", "Power connected"))
        XCTAssertEqual(center.currentNotice, first, "Another module's notice waits its turn")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["power"])
        XCTAssertGreaterThan(center.noticeRevision(for: .battery), first.revision)
        XCTAssertEqual(center.noticeRevision(for: .timer), 0)
    }

    func testWithdrawNoticeClearsOnlyItsOwnModuleAndKey() {
        let center = makeCenter()
        let shelf = center.messenger(for: .shelf)
        let battery = center.messenger(for: .battery)
        shelf.post(.removed)

        battery.withdrawNotice(ShelfNotice.removed.rawValue)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.removed.rawValue,
                       "Another module cannot withdraw a Shelf notice")
        shelf.withdrawNotice(ShelfNotice.reconnected.rawValue)
        XCTAssertNotNil(center.currentNotice, "A different key leaves the notice in place")
        shelf.withdrawNotice(ShelfNotice.removed.rawValue)
        XCTAssertNil(center.currentNotice)
    }

    func testWithdrawNoticeRemovesWaitingCopyAndVisibleOneAdvancesQueue() {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        center.messenger(for: .battery).post(plain("power"))
        center.messenger(for: .timer).post(plain("done"))

        center.messenger(for: .battery).withdrawNotice("power")
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.timer])
        center.messenger(for: .shelf).withdrawNotice(ShelfNotice.removed.rawValue)
        XCTAssertEqual(center.currentNotice?.moduleID, .timer)
        XCTAssertTrue(center.waitingNotices.isEmpty)
    }

    func testInertMessengerHasNoCenter() {
        XCTAssertFalse(ModuleMessenger.inert.isConnected, "inert must not reach any message center")
        let center = makeCenter()
        XCTAssertTrue(center.messenger(for: .shelf).isConnected)
        // Posting and withdrawing through an inert messenger is a safe no-op.
        ModuleMessenger.inert.post(.alreadyOnShelf)
        ModuleMessenger.inert.withdrawNotice(ShelfNotice.alreadyOnShelf.rawValue)
        XCTAssertNil(center.currentNotice)
    }

    func testPerformRoutesActionDismissesNoticeAndAdvancesQueue() {
        let center = makeCenter()
        var routed: [IslandNoticeAction] = []
        center.routeAction = { routed.append($0) }
        center.messenger(for: .shelf).post(.receivedAwaitingRecovery)
        center.messenger(for: .battery).post(plain("power"))

        center.perform(.openStorageRecovery)
        XCTAssertEqual(routed, [.openStorageRecovery])
        XCTAssertEqual(center.currentNotice?.notice.key, "power")

        center.perform(.openModule(.timer))
        XCTAssertEqual(routed, [.openStorageRecovery, .openModule(.timer)])
        XCTAssertNil(center.currentNotice)
    }

    func testActionTitles() {
        XCTAssertEqual(IslandNoticeAction.openStorageRecovery.title, "Open Recovery")
        XCTAssertEqual(IslandNoticeAction.openModule(.timer).title, "Show")
    }

    // MARK: - Rule 1: same key replaces in place

    func testSameKeyReplacesVisibleCopyInPlaceWithoutSpeakingUnchangedText() throws {
        let center = makeCenter()
        let battery = center.messenger(for: .battery)
        battery.post(plain("power", "Power connected"))
        let first = try XCTUnwrap(center.currentNotice)
        XCTAssertEqual(spoken.messages, ["Power connected"])

        battery.post(plain("power", "Power connected"))
        let repeated = try XCTUnwrap(center.currentNotice)
        XCTAssertEqual(repeated.id, first.id, "A repeat keeps the pill, so it does not animate again")
        XCTAssertGreaterThan(repeated.revision, first.revision)
        XCTAssertEqual(spoken.messages, ["Power connected"], "Unchanged text is not spoken again")

        battery.post(plain("power", "Running on battery"))
        XCTAssertEqual(center.currentNotice?.id, first.id)
        XCTAssertEqual(center.currentNotice?.notice.title, "Running on battery")
        XCTAssertEqual(spoken.messages, ["Power connected", "Running on battery"])
        XCTAssertTrue(center.waitingNotices.isEmpty)
    }

    func testSameKeyReplacesWaitingCopyInPlace() throws {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        let battery = center.messenger(for: .battery)
        battery.post(plain("power", "Power connected"))
        center.messenger(for: .timer).post(plain("done"))
        let waiting = try XCTUnwrap(center.waitingNotices.first)

        battery.post(plain("power", "Running on battery"))
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.battery, .timer], "It keeps its place in line")
        XCTAssertEqual(center.waitingNotices.first?.id, waiting.id)
        XCTAssertEqual(center.waitingNotices.first?.notice.title, "Running on battery")
        XCTAssertEqual(spoken.messages.filter { $0 == "Running on battery" }.count, 1)
    }

    func testSameKeyRestartsVisibleTime() async {
        let center = makeCenter()
        let battery = center.messenger(for: .battery)
        battery.post(plain("power"))
        await clock.advance(by: 3)
        battery.post(plain("power"))
        await clock.advance(by: 3)
        XCTAssertNotNil(center.currentNotice, "A replaced notice gets its full time again")
        await clock.advance(by: 1)
        XCTAssertNil(center.currentNotice)
    }

    func testSameKeyRepostCannotHoldThePillWhileOthersWait() async {
        let center = makeCenter()
        let battery = center.messenger(for: .battery)
        battery.post(plain("power"))
        center.messenger(for: .shelf).post(.receivedAwaitingRecovery)
        await clock.advance(by: 1.5)
        battery.post(plain("power", "Power connected · 16%"))
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)
        await clock.advance(by: 0.5)
        XCTAssertEqual(center.currentNotice?.moduleID, .shelf,
                       "The handoff still happens at 2 s on screen")
    }

    // MARK: - Rule 2: same module, plain replaces plain

    func testSameModulePlainNoticeWaitsItsTurnWhileOthersWait() async {
        let center = makeCenter()
        let shelf = center.messenger(for: .shelf)
        shelf.post(.removed)
        center.messenger(for: .battery).post(plain("power"))
        await clock.advance(by: 1.5)
        shelf.post(.alreadyOnShelf)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.removed.rawValue)
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["power", ShelfNotice.alreadyOnShelf.rawValue])
        await clock.advance(by: 0.5)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)
    }

    func testSameModulePlainNoticeReplacesVisiblePlainNoticeImmediately() {
        let center = makeCenter()
        let shelf = center.messenger(for: .shelf)
        shelf.post(.removed)
        let removed = center.currentNotice
        shelf.post(.alreadyOnShelf)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.alreadyOnShelf.rawValue)
        XCTAssertNotEqual(center.currentNotice?.id, removed?.id)
        XCTAssertTrue(center.waitingNotices.isEmpty)

        shelf.post(.receivedAwaitingRecovery)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.alreadyOnShelf.rawValue,
                       "A notice with a button never replaces another")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), [ShelfNotice.receivedAwaitingRecovery.rawValue])
        shelf.post(.removed)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.alreadyOnShelf.rawValue,
                       "While a notice waits, a new plain notice takes its turn instead")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key),
                       [ShelfNotice.receivedAwaitingRecovery.rawValue, ShelfNotice.removed.rawValue])
    }

    func testSameModulePlainNoticeDoesNotReplaceVisibleNoticeWithAction() {
        let center = makeCenter()
        let shelf = center.messenger(for: .shelf)
        shelf.post(.moveRecoveryNeedsAttention)
        shelf.post(.removed)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.moveRecoveryNeedsAttention.rawValue)
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), [ShelfNotice.removed.rawValue])
    }

    // MARK: - Rule 3: queue

    func testCrossModuleNoticesQueueInOrderAndVisibleOneEndsAfterTwoSeconds() async {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        await clock.advance(by: 1)
        center.messenger(for: .battery).post(plain("power"))
        center.messenger(for: .timer).post(plain("done"))

        await clock.advance(by: 0.9)
        XCTAssertEqual(center.currentNotice?.moduleID, .shelf)
        await clock.advance(by: 0.1)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery, "The visible notice ends at 2 s on screen")
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.timer])

        await clock.advance(by: 2)
        XCTAssertEqual(center.currentNotice?.moduleID, .timer)
        await clock.advance(by: 3.9)
        XCTAssertEqual(center.currentNotice?.moduleID, .timer, "With nothing waiting, the full duration applies")
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)
    }

    func testVisibleNoticeLongerThanTwoSecondsHandsOverImmediately() async {
        let center = makeCenter()
        center.messenger(for: .shelf).post(plain("long", duration: 10))
        await clock.advance(by: 3)
        center.messenger(for: .battery).post(plain("power"))
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)
    }

    func testShortNoticeKeepsItsOwnRemainingTimeWhileOthersWait() async {
        let center = makeCenter()
        center.messenger(for: .shelf).post(plain("short", duration: 2))
        await clock.advance(by: 1.5)
        center.messenger(for: .battery).post(plain("power"))
        await clock.advance(by: 0.5)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)
    }

    func testQueueCapDropsOldestWaitingNoticeWithoutAction() {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        center.messenger(for: .battery).post(actionable("a"))
        center.messenger(for: .timer).post(plain("b"))
        center.messenger(for: .system).post(plain("c"))
        center.messenger(for: .media).post(actionable("d"))
        XCTAssertEqual(center.waitingNotices.count, IslandMessageCenter.queueCapacity)

        center.messenger(for: .aiUsage).post(plain("e"))
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["a", "c", "d", "e"])
    }

    func testFullQueueOfActionsDropsOldest() {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        for (module, key) in [(IslandModuleID.battery, "a"), (.timer, "b"), (.system, "c"), (.media, "d")] {
            center.messenger(for: module).post(actionable(key))
        }
        center.messenger(for: .aiUsage).post(actionable("e"))
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["b", "c", "d", "e"])
    }

    // MARK: - Durations and the visible-time clock

    func testDurationDefaultsAndClamping() {
        XCTAssertEqual(IslandMessageCenter.duration(for: plain("a")), 4)
        XCTAssertEqual(IslandMessageCenter.duration(for: actionable("a")), 8)
        XCTAssertEqual(IslandMessageCenter.duration(for: plain("a", duration: 2.5)), 2.5)
        XCTAssertEqual(IslandMessageCenter.duration(for: plain("a", duration: 0.1)), 2)
        XCTAssertEqual(IslandMessageCenter.duration(for: plain("a", duration: 30)), 10)
        var long = actionable("a")
        long.duration = 60
        XCTAssertEqual(IslandMessageCenter.duration(for: long), 10)
    }

    func testDefaultAndClampedDurationsExpireOnTime() async {
        let center = makeCenter()
        let shelf = center.messenger(for: .shelf)
        shelf.post(plain("default"))
        await clock.advance(by: 3.9)
        XCTAssertNotNil(center.currentNotice)
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)

        shelf.post(plain("tiny", duration: 0.1))
        await clock.advance(by: 1.9)
        XCTAssertNotNil(center.currentNotice, "Durations below 2 s are raised to 2 s")
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)

        shelf.post(.receivedAwaitingRecovery)
        await clock.advance(by: 7.9)
        XCTAssertNotNil(center.currentNotice, "A notice with a button lasts 8 s")
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)
    }

    func testClockCountsOnlyRunningTimeAndKeepsRemainingTimeAcrossPauses() async {
        let center = makeCenter(running: false)
        center.messenger(for: .shelf).post(.removed)
        await clock.advance(by: 100)
        XCTAssertNotNil(center.currentNotice, "Waiting time does not count")

        center.setNoticeClockRunning(true)
        await clock.advance(by: 3)
        center.setNoticeClockRunning(false)
        await clock.advance(by: 100)
        XCTAssertNotNil(center.currentNotice, "Hovered or dragging time does not count")

        center.setNoticeClockRunning(true)
        await clock.advance(by: 0.9)
        XCTAssertNotNil(center.currentNotice, "The pause did not restart the notice")
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)
    }

    func testFractionalStepsAcrossPausesLandExactlyOnTheDeadline() async {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        await clock.advance(by: 3)
        for step in [0.3, 0.3] {
            center.setNoticeClockRunning(false)
            center.setNoticeClockRunning(true)
            await clock.advance(by: step)
        }
        XCTAssertNotNil(center.currentNotice)
        await clock.advance(by: 0.4)
        XCTAssertNil(center.currentNotice, "3 + 0.3 + 0.3 + 0.4 s is exactly the 4 s default")
    }

    func testClockStartsStoppedSoEarlyNoticesWaitForAPresenter() async {
        let center = IslandMessageCenter(clock: clock, announcer: .recording(into: spoken))
        XCTAssertFalse(center.isNoticeClockRunning)
        center.messenger(for: .shelf).post(.moveRecoveryNeedsAttention)
        await clock.advance(by: 60)
        XCTAssertNotNil(center.currentNotice)
    }

    // MARK: - Speech

    func testNoticesAreSpokenWhenPostedEvenWhileWaiting() {
        let center = makeCenter(running: false)
        center.messenger(for: .shelf).post(.removed)
        center.messenger(for: .battery).post(plain("power", "Power connected"))
        XCTAssertEqual(center.waitingNotices.count, 1)
        XCTAssertEqual(spoken.messages, [ShelfNotice.removed.text, "Power connected"],
                       "A waiting notice is spoken right away")
    }

    func testAnnouncementPriorityTokenAndActionSentence() throws {
        let center = makeCenter()
        let battery = center.messenger(for: .battery)
        battery.post(plain("info", tone: .info))
        battery.post(plain("success", tone: .success))
        battery.post(plain("warning", tone: .warning))
        battery.post(plain("error", tone: .error))
        center.messenger(for: .shelf).post(.moveRecoveryNeedsAttention)

        XCTAssertEqual(spoken.announcements.map(\.priority), [.low, .low, .medium, .high, .high])
        XCTAssertEqual(spoken.announcements.first?.token, "notice.battery.info.1")
        let recovery = try XCTUnwrap(spoken.announcements.last)
        XCTAssertEqual(recovery.token,
                       "notice.shelf.\(ShelfNotice.moveRecoveryNeedsAttention.rawValue).\(center.noticeRevision(for: .shelf))")
        XCTAssertTrue(recovery.message.hasPrefix(ShelfNotice.moveRecoveryNeedsAttention.text))
        XCTAssertTrue(recovery.message.hasSuffix("Open Recovery is available."), recovery.message)
    }

    func testAnnouncementTokensAreDeduplicated() {
        let center = AccessibilityAnnouncementCenter.recording(into: spoken)
        let announcement = AccessibilityAnnouncement(token: "notice.shelf.removed.1", message: "Removed",
                                                     priority: .low)
        center.announce(announcement)
        center.announce(announcement)
        XCTAssertEqual(spoken.messages, ["Removed"])
    }

    // MARK: - Drag handshake

    func testDragHandshakeCountsOnlyNewShelfNotices() {
        for (module, collapses) in [(IslandModuleID.shelf, true), (.battery, false)] {
            let center = makeCenter()
            let coordinator = IslandActivityCoordinator()
            let before = center.noticeRevision(for: .shelf)
            coordinator.beginDrag()
            center.messenger(for: module).post(plain("feedback"))
            coordinator.endDrag(imported: true,
                                hasPendingNotice: center.hasNewCurrentNotice(from: .shelf, since: before))
            XCTAssertEqual(coordinator.surfaceState, collapses ? .collapsed : .expanded,
                           "\(module.rawValue) notice during a drag")
        }
    }

    func testDragHandshakeIgnoresShelfNoticeFromBeforeTheDrag() {
        let center = makeCenter()
        center.messenger(for: .shelf).post(.removed)
        let before = center.noticeRevision(for: .shelf)
        XCTAssertFalse(center.hasNewCurrentNotice(from: .shelf, since: before))
        center.messenger(for: .shelf).post(.alreadyOnShelf)
        XCTAssertTrue(center.hasNewCurrentNotice(from: .shelf, since: before))
    }

    // MARK: - Add Clipboard Image

    func testClipboardImageCommandOpensShelfOnlyForScheduledImages() {
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 0), .notice(.clipboardHasNoImage))
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 1), .showShelf)
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 3), .showShelf)
    }
}
