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

    // MARK: - The reported bug: a notice never clears a status

    private let low = IslandStatus(key: "low", title: "Battery low", detail: "15%",
                                   systemImage: "battery.25percent", tone: .critical)

    private func assertNoticeNeverClearsStatus(_ notice: IslandNotice,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        let center = makeCenter()
        center.moduleDidStart(.battery)
        let battery = center.messenger(for: .battery)
        battery.setStatus(low)
        await clock.advance(by: IslandMessageCenter.actionDuration)
        XCTAssertNil(center.currentNotice, "The raised notice has finished", file: file, line: line)
        let red = IslandNotchIndicator(systemImage: "battery.25percent", tint: .critical, accessibilityText: "Battery low")
        XCTAssertEqual(resolve(.battery, center), red, file: file, line: line)

        battery.post(notice)
        center.setVisibleNotice(center.currentNotice?.id)
        await clock.advance(by: 1)
        XCTAssertEqual(resolve(.battery, center)?.systemImage, notice.systemImage, file: file, line: line)
        XCTAssertEqual(resolve(.battery, center)?.accessibilityTexts.first, "Battery low",
                       "VoiceOver still hears the status", file: file, line: line)
        XCTAssertEqual(center.statuses(for: .battery), [low], file: file, line: line)

        await clock.advance(by: 2)
        XCTAssertNil(center.currentNotice, file: file, line: line)
        XCTAssertEqual(resolve(.battery, center), red, "Low is back without being set again", file: file, line: line)
        XCTAssertEqual(center.statuses(for: .battery), [low], file: file, line: line)
    }

    private func resolve(_ display: IslandModuleID, _ center: IslandMessageCenter) -> IslandNotchIndicator? {
        IslandNotchIndicatorResolver.resolve(display: display, center: center, isDragInProgress: false)
    }

    func testNoticeNeverClearsStatus() async {
        await assertNoticeNeverClearsStatus(IslandNotice(
            key: "power", title: "Power connected · 15%", detail: "Power connected, 15%",
            systemImage: "bolt.fill", duration: 2.5))
    }

    func testLowPowerModeNoticeNeverClearsStatus() async {
        await assertNoticeNeverClearsStatus(IslandNotice(
            key: "low-power-mode", title: "Low Power Mode enabled", systemImage: "leaf.fill", duration: 2.5))
    }

    // MARK: - Statuses

    private func status(_ key: String, _ title: String? = nil, detail: String? = nil,
                        tone: IslandStatus.Tone = .neutral, level: Int = 0, announces: Bool = true,
                        dismissible: Bool = false, expiresAt: Duration? = nil) -> IslandStatus {
        IslandStatus(key: key, title: title ?? key, detail: detail, systemImage: "circle", tone: tone,
                     level: level, announcesWhenRaised: announces, isDismissible: dismissible,
                     expiresAt: expiresAt)
    }

    private func startedCenter(_ modules: IslandModuleID...) -> IslandMessageCenter {
        let center = makeCenter()
        for module in modules { center.moduleDidStart(module) }
        return center
    }

    func testRaisedWarningIsSpokenOnceAndQueuesOneNotice() throws {
        let center = startedCenter(.system)
        let system = center.messenger(for: .system)
        system.setStatus(status("disk", "Disk space is low", detail: "2 GB", tone: .warning))
        XCTAssertEqual(spoken.messages, ["Disk space is low, 2 GB. Show is available."])
        XCTAssertEqual(spoken.announcements.last?.priority, .medium)
        let notice = try XCTUnwrap(center.currentNotice)
        XCTAssertEqual(notice.raisedStatusKey, "disk")
        XCTAssertEqual(notice.notice.key, "status.disk")
        XCTAssertEqual(notice.notice.title, "Disk space is low · 2 GB")
        XCTAssertEqual(notice.notice.fullText, "Disk space is low, 2 GB")
        XCTAssertEqual(notice.notice.tone, .warning)
        XCTAssertEqual(notice.notice.action, .openModule(.system), "Show opens the panel on the module")

        system.setStatus(status("disk", "Disk space is low", detail: "1 GB", tone: .warning))
        XCTAssertEqual(spoken.messages.count, 1, "A detail-only change is silent")
        XCTAssertEqual(center.currentNotice, notice, "and leaves the notice alone")
        XCTAssertEqual(center.topStatus(for: .system)?.detail, "1 GB")

        system.setStatus(status("disk", "Disk space is very low", detail: "1 GB", tone: .warning))
        XCTAssertEqual(spoken.messages.count, 1, "A title-only change is silent")
        XCTAssertEqual(center.currentNotice?.id, notice.id)

        system.setStatus(status("disk", "Disk space is critically low", detail: "1 GB", tone: .warning, level: 1))
        XCTAssertEqual(spoken.messages.last, "Disk space is critically low, 1 GB. Show is available.",
                       "A higher level raises it again")
        XCTAssertEqual(spoken.messages.count, 2)
        XCTAssertEqual(center.currentNotice?.id, notice.id, "Its notice updates in place")
        XCTAssertEqual(center.currentNotice?.notice.title, "Disk space is critically low · 1 GB")

        system.setStatus(status("disk", "Disk space is low", detail: "2 GB", tone: .warning, level: 0))
        XCTAssertEqual(spoken.messages.count, 2, "A lower level is silent")
        system.setStatus(status("disk", "Disk space is critically low", detail: "1 GB", tone: .warning, level: 1))
        XCTAssertEqual(spoken.messages.count, 3, "Getting worse again raises it again")

        system.setStatus(status("disk", "Disk space is critically low", detail: "1 GB", tone: .critical))
        XCTAssertEqual(spoken.messages.count, 4, "A higher tone raises it again, even at a lower level")
        XCTAssertEqual(spoken.announcements.last?.priority, .high)
        XCTAssertEqual(center.currentNotice?.notice.tone, .error)

        system.setStatus(status("disk", "Disk space is critically low", detail: "1 GB", tone: .warning, level: 2))
        XCTAssertEqual(spoken.messages.count, 4, "A lower tone is not a raise, whatever its level")
        XCTAssertTrue(center.waitingNotices.isEmpty)
    }

    func testOnlyAnnouncingWarningAndCriticalStatusesAreRaisedAloud() {
        let center = startedCenter(.system)
        let system = center.messenger(for: .system)
        system.setStatuses([status("quiet", tone: .critical, announces: false),
                            status("neutral"), status("progress", tone: .progress)])
        XCTAssertTrue(spoken.messages.isEmpty)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(center.statuses(for: .system).count, 3)
    }

    func testRaisedNoticeIsWithdrawnWhenTheStatusClearsFirst() {
        let center = startedCenter(.battery, .system)
        center.messenger(for: .system).setStatus(status("disk", tone: .warning))
        center.messenger(for: .battery).setStatus(low)
        XCTAssertEqual(center.waitingNotices.map(\.raisedStatusKey), ["low"])
        center.messenger(for: .battery).clearStatus("low")
        XCTAssertTrue(center.waitingNotices.isEmpty, "A waiting notice goes with its status")
        center.messenger(for: .system).clearStatus("disk")
        XCTAssertNil(center.currentNotice, "So does a visible one")
    }

    func testRaisedNoticeIsWithdrawnWhenItsModuleBecomesShown() {
        let center = startedCenter(.battery, .timer)
        center.messenger(for: .timer).setStatus(status("finished", "Timer finished", tone: .warning))
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .battery).post(plain("power"))
        XCTAssertEqual(center.currentNotice?.raisedStatusKey, "finished")

        center.setShownModule(.timer, othersWait: false)
        XCTAssertEqual(center.currentNotice?.raisedStatusKey, "low")
        center.setShownModule(.battery, othersWait: false)
        XCTAssertEqual(center.currentNotice?.notice.key, "power", "Plain notices stay")
        XCTAssertTrue(center.waitingNotices.isEmpty)
        XCTAssertEqual(center.statuses(for: .battery), [low], "The status itself stays")
    }

    func testRaisedStatusOfTheShownModuleIsSpokenWithoutAPill() {
        let center = startedCenter(.timer)
        center.setShownModule(.timer, othersWait: true)
        center.messenger(for: .timer).setStatus(status("finished", "Timer finished", tone: .warning))
        XCTAssertEqual(spoken.messages, ["Timer finished"], "No pill, so no Show to name")
        XCTAssertNil(center.currentNotice)
    }

    func testRaisedAndPlainNoticeFromOneSampleBothShow() async {
        let center = startedCenter(.battery)
        let battery = center.messenger(for: .battery)
        battery.setStatuses([low])
        battery.post(plain("power", "Running on battery"))
        XCTAssertEqual(center.currentNotice?.raisedStatusKey, "low", "The plain notice does not replace it")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["power"])
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        XCTAssertEqual(center.currentNotice?.notice.title, "Running on battery")
    }

    func testStatusesAreScopedPerModule() {
        let center = startedCenter(.battery, .system)
        center.messenger(for: .battery).setStatus(status("alert", "Battery alert"))
        center.messenger(for: .system).setStatus(status("alert", "System alert"))
        center.messenger(for: .system).setStatuses([])
        XCTAssertEqual(center.statuses(for: .battery).map(\.title), ["Battery alert"])
        XCTAssertTrue(center.statuses(for: .system).isEmpty)
        center.messenger(for: .system).clearStatus("alert")
        center.messenger(for: .battery).clearStatus("other")
        XCTAssertEqual(center.statuses(for: .battery).count, 1)
    }

    func testEqualStatusesCauseNoObservationChange() {
        let center = startedCenter(.battery)
        let battery = center.messenger(for: .battery)
        battery.setStatuses([low, status("other")])
        let probe = ObservationProbe()
        probe.track { _ = center.statuses(for: .battery) }
        battery.setStatuses([status("other"), low])
        battery.setStatus(low)
        battery.clearStatus("missing")
        XCTAssertEqual(probe.changes, 0)

        battery.setStatuses([low])
        XCTAssertEqual(probe.changes, 1)
        battery.setStatuses([status("a"), status("b"), status("c")])
        XCTAssertEqual(probe.changes, 2, "Replacing the whole set is one change")
        battery.setStatus(status("a", detail: "1"))
        battery.setStatus(status("b", detail: "1"))
        XCTAssertEqual(probe.changes, 4, "The probe counts every change")
    }

    /// The notch reads `visibleNotice`, which only the presenter turns on.
    func testVisibleNoticeIsTheCurrentNoticeOnScreen() async throws {
        let center = makeCenter()
        center.messenger(for: .shelf).post(plain("a"))
        let first = try XCTUnwrap(center.currentNotice)
        XCTAssertNil(center.visibleNotice, "Current but not on screen yet")
        center.setVisibleNotice(first.id)
        XCTAssertEqual(center.visibleNotice?.id, first.id)
        center.messenger(for: .shelf).post(plain("a", "A again"))
        XCTAssertEqual(center.visibleNotice?.notice.title, "A again", "An in-place replace stays on screen")

        center.messenger(for: .timer).post(plain("b"))
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        XCTAssertEqual(center.currentNotice?.notice.key, "b")
        XCTAssertNil(center.visibleNotice, "The next notice is not on screen until the presenter says so")

        center.setVisibleNotice(center.currentNotice?.id)
        XCTAssertNotNil(center.visibleNotice)
        center.setVisibleNotice(nil)
        XCTAssertNil(center.visibleNotice, "Waiting, for example during a drag")
        XCTAssertEqual(center.currentNotice?.notice.key, "b")
    }

    func testSetStatusesKeepsTheRaiseOrderOfStatusesThatStay() {
        let center = startedCenter(.system)
        let system = center.messenger(for: .system)
        system.setStatuses([status("a")])
        system.setStatuses([status("a"), status("b")])
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["b", "a"], "b was raised last")
        system.setStatuses([status("b"), status("a", detail: "new detail")])
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["b", "a"], "Staying or a new detail is not a raise")
        system.setStatuses([status("b"), status("a", "A again")])
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["b", "a"], "A new title is not a raise")
        system.setStatuses([status("b", level: 1), status("a", "A again")])
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["b", "a"], "A higher level orders first")
        system.setStatuses([status("b"), status("a", level: 1)])
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["a", "b"], "A higher level raises it")
    }

    func testTopStatusOrdersByToneThenLevelThenRecency() {
        let center = startedCenter(.system)
        let system = center.messenger(for: .system)
        system.setStatus(status("warning", tone: .warning, announces: false))
        system.setStatus(status("newer", tone: .progress))
        XCTAssertEqual(center.topStatus(for: .system)?.key, "warning")
        system.setStatus(status("newest warning", tone: .warning, announces: false))
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["newest warning", "warning", "newer"])
        system.setStatus(status("warning", tone: .warning, level: 1, announces: false))
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["warning", "newest warning", "newer"],
                       "Within a tone, a higher level comes first")
        XCTAssertNil(center.topStatus(for: .battery))
    }

    func testExpiredStatusPrunesItselfUnderTheTestClock() async {
        let center = startedCenter(.aiUsage)
        let aiUsage = center.messenger(for: .aiUsage)
        aiUsage.setStatus(status("limit", tone: .warning, announces: false, expiresAt: aiUsage.expiry(after: .seconds(600))))
        aiUsage.setStatus(status("later", expiresAt: aiUsage.expiry(after: .seconds(900))))
        await clock.advance(by: 599.9)
        XCTAssertEqual(center.statuses(for: .aiUsage).map(\.key), ["limit", "later"])
        await clock.advance(by: 0.1)
        XCTAssertEqual(center.statuses(for: .aiUsage).map(\.key), ["later"])
        await clock.advance(by: 300)
        XCTAssertTrue(center.statuses(for: .aiUsage).isEmpty)
        aiUsage.setStatus(status("stale", expiresAt: center.now))
        XCTAssertTrue(center.statuses(for: .aiUsage).isEmpty, "An already expired status is not added")
    }

    func testDismissedStatusStaysHiddenUntilClearedAndRaisedAgain() {
        let center = startedCenter(.system)
        let system = center.messenger(for: .system)
        system.setStatus(status("memory", "Memory pressure is high", tone: .warning, dismissible: true))
        system.setStatus(status("fixed", "Can't be hidden", tone: .warning, announces: false))
        XCTAssertEqual(spoken.messages, ["Memory pressure is high. Show is available."])

        center.dismissStatus("fixed", of: .system)
        center.dismissStatus("memory", of: .system)
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["fixed"])
        XCTAssertNil(center.currentNotice, "Dismissing withdraws its notice")

        system.setStatus(status("memory", "Memory pressure is critical", tone: .critical, dismissible: true))
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["fixed"], "Hidden while the module keeps setting it")
        XCTAssertEqual(spoken.messages.count, 1, "and silent")

        system.clearStatus("memory")
        system.setStatus(status("memory", "Memory pressure is high", tone: .warning, dismissible: true))
        XCTAssertEqual(center.statuses(for: .system).map(\.key), ["memory", "fixed"])
        XCTAssertEqual(spoken.messages.count, 2)
    }

    // MARK: - Lifecycle

    func testStatusesFromAModuleThatHasNotStartedAreIgnored() {
        let center = makeCenter()
        let timer = center.messenger(for: .timer)
        timer.setStatus(status("running"))
        timer.setStatuses([status("running")])
        XCTAssertTrue(center.statuses(for: .timer).isEmpty)
        XCTAssertFalse(center.isModuleStarted(.timer))
        timer.post(plain("done"))
        XCTAssertEqual(center.currentNotice?.moduleID, .timer, "Notices are not gated")
    }

    func testModuleDidStopClearsStatusesAndTheirPendingPillsButKeepsNotices() async throws {
        let center = startedCenter(.battery, .timer)
        let battery = center.messenger(for: .battery)
        battery.post(plain("power"))
        let visible = try XCTUnwrap(center.currentNotice)
        center.setVisibleNotice(visible.id)
        center.messenger(for: .timer).post(plain("done"))
        battery.setStatus(status("low", "Battery low", tone: .critical))
        battery.post(actionable("recovery"))
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["done", "status.low", "recovery"])

        center.moduleDidStop(.battery)
        XCTAssertTrue(center.statuses(for: .battery).isEmpty)
        XCTAssertEqual(center.currentNotice, visible, "The notice on screen finishes")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), ["done", "recovery"],
                       "The cleared status's pill goes; a notice about something that happened stays")
        battery.setStatus(status("late"))
        XCTAssertTrue(center.statuses(for: .battery).isEmpty, "A stopped module cannot set statuses")
    }

    func testModuleDidStopDropsAStatusPillThatNeverAppeared() {
        let center = startedCenter(.battery)
        center.setShownModule(.shelf, othersWait: true)
        center.messenger(for: .battery).setStatus(status("low", "Battery low", tone: .critical))
        XCTAssertEqual(center.currentNotice?.raisedStatusKey, "low")
        center.moduleDidStop(.battery)
        XCTAssertNil(center.currentNotice, "It never appeared, and its status is gone")
    }

    func testModuleDidStopKeepsShelfNoticesWhenThePanelStopsEveryModule() {
        let center = startedCenter(.shelf)
        center.setShownModule(.timer, othersWait: true)
        center.messenger(for: .shelf).post(.moveRecoveryNeedsAttention)
        center.messenger(for: .shelf).post(.removed)
        center.moduleDidStop(.shelf)
        XCTAssertEqual(center.currentNotice?.notice.key, ShelfNotice.moveRecoveryNeedsAttention.rawValue,
                       "A startup recovery notice survives the Panel deactivating")
        XCTAssertEqual(center.waitingNotices.map(\.notice.key), [ShelfNotice.removed.rawValue])
    }

    // MARK: - The shown module and the queue

    func testShownModuleNoticeGoesAheadOfNoticesWaitingForThePanel() async {
        let center = makeCenter()
        center.setShownModule(.timer, othersWait: true)
        center.messenger(for: .battery).post(plain("power"))
        center.messenger(for: .shelf).post(.removed)
        center.messenger(for: .timer).post(plain("done"))
        XCTAssertEqual(center.currentNotice?.moduleID, .timer, "It does not wait behind notices held by the panel")
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.battery, .shelf], "They keep their order")

        center.messenger(for: .timer).post(plain("again", duration: 2))
        XCTAssertEqual(center.currentNotice?.notice.key, "again", "Plain replaces plain: nothing ready waits")

        await clock.advance(by: 2)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)
        center.setShownModule(nil, othersWait: false)
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        XCTAssertEqual(center.currentNotice?.moduleID, .shelf, "Once the panel closes, the rest show in order")
    }

    func testShownModuleNoticeDoesNotReplaceANoticeThatAppeared() throws {
        let center = makeCenter()
        center.messenger(for: .battery).post(plain("power"))
        let visible = try XCTUnwrap(center.currentNotice)
        center.setVisibleNotice(visible.id)
        center.setShownModule(.timer, othersWait: true)
        center.messenger(for: .shelf).post(.removed)
        center.messenger(for: .timer).post(plain("done"))
        XCTAssertEqual(center.currentNotice, visible)
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.timer, .shelf])
    }

    func testShowingAModuleLetsItsWaitingNoticesGoFirst() {
        let center = makeCenter()
        center.setShownModule(.shelf, othersWait: true)
        center.messenger(for: .battery).post(plain("power"))
        center.messenger(for: .timer).post(plain("done"))
        center.messenger(for: .clipboard).post(plain("copied"))
        center.setShownModule(.clipboard, othersWait: true)
        XCTAssertEqual(center.currentNotice?.moduleID, .clipboard)
        XCTAssertEqual(center.waitingNotices.map(\.moduleID), [.battery, .timer])
    }

    func testHandoffOnlyShortensTheVisibleNoticeForOneThatCouldAppear() async throws {
        let center = makeCenter()
        center.setShownModule(.shelf, othersWait: true)
        center.messenger(for: .shelf).post(.removed)
        let shelf = try XCTUnwrap(center.currentNotice)
        center.setVisibleNotice(shelf.id)
        center.messenger(for: .battery).post(plain("power"))
        await clock.advance(by: 3.9)
        XCTAssertEqual(center.currentNotice, shelf, "The waiting notice could not appear, so no handoff")
        await clock.advance(by: 0.1)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery)

        center.messenger(for: .shelf).post(.alreadyOnShelf)
        XCTAssertEqual(center.currentNotice?.moduleID, .shelf)
        center.setVisibleNotice(try XCTUnwrap(center.currentNotice).id)
        center.setShownModule(.shelf, othersWait: false)
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        XCTAssertEqual(center.currentNotice?.moduleID, .battery, "In a pinned panel it could, so the handoff applies")
    }

    // MARK: - Add Clipboard Image

    func testClipboardImageCommandOpensShelfOnlyForScheduledImages() {
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 0), .notice(.clipboardHasNoImage))
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 1), .showShelf)
        XCTAssertEqual(ClipboardImageImportOutcome(scheduledCount: 3), .showShelf)
    }
}
