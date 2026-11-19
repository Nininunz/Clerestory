import AppKit
import XCTest
@testable import Clerestory

@MainActor
final class IslandNoticePanelTests: XCTestCase {
    private let clock = ManualMessageClock()

    private func makeMessages() -> IslandMessageCenter {
        IslandMessageCenter.forTesting(clock: clock)
    }

    /// A pointer far from the pill, so the real mouse position cannot hold a notice.
    private func makeController(anchor: NSWindow, messages: IslandMessageCenter,
                                coordinator: IslandActivityCoordinator, settings: SettingsStore,
                                dropTarget: DropTargetState = DropTargetState()) -> IslandNoticePanelController {
        IslandNoticePanelController(anchor: anchor, messages: messages, coordinator: coordinator,
                                    settings: settings, dropTarget: dropTarget,
                                    pointerLocation: { CGPoint(x: -10_000, y: -10_000) })
    }

    // These tests create real windows. Keep the fixture and the pill's shadow
    // inside the host display so AppKit's screen-edge constraints do not move
    // them. Screen-edge/notch geometry is covered by the pure layout tests.
    private func liveLayout() throws -> IslandGeometryResolver.Layout {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let testArea = screen.visibleFrame.insetBy(dx: 40, dy: 80)
        return IslandGeometryResolver.resolve(screen: .init(
            frame: testArea,
            visibleFrame: testArea,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero))
    }

    func testUnpinnedNoticeWaitsWithoutExpiringAndIgnoresStaleCloseCompletion() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let messages = makeMessages()
        // The panel shows Shelf, so a notice from another module waits for it to close.
        let battery = messages.messenger(for: .battery)
        let power = IslandNotice(key: "power", title: "Power connected")
        let anchor = NSWindow(contentRect: layout.expandedFrame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        battery.post(power)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(messages.isNoticeClockRunning, "Waiting time does not count")
        await clock.advance(by: 60)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(messages.currentNotice?.notice, power)
        coordinator.collapse()
        let oldClose = coordinator.surfaceTransitionID
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(oldClose)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.panel.isVisible)
        coordinator.collapse()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.panel.isVisible)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(messages.isNoticeClockRunning)
        await clock.advance(by: IslandMessageCenter.defaultDuration)
        XCTAssertNil(messages.currentNotice)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(controller.panel.isVisible)
    }

    func testReopeningPushesVisiblePillBelowExpandedIsland() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        let messages = makeMessages()
        let shelf = messages.messenger(for: .shelf)
        let anchor = NSWindow(contentRect: layout.notchFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        shelf.post(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible)
        let notchPill = try XCTUnwrap(controller.interactionFrame)
        anchor.setFrame(layout.expandedFrame, display: true)
        let expandedAnchorFrame = anchor.frame
        coordinator.show(module: .shelf)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.panel.isVisible, "Reopening must not hide a displayed pill")
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(450))
        let expandedPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(expandedPill.maxY, expandedAnchorFrame.minY - 10, accuracy: 1)
        XCTAssertLessThan(expandedPill.maxY, notchPill.maxY)
        XCTAssertEqual(expandedPill.midX, expandedAnchorFrame.midX, accuracy: 1)
        coordinator.collapse()
        anchor.setFrame(layout.notchFrame, display: true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(try XCTUnwrap(controller.interactionFrame).maxY, notchPill.maxY, accuracy: 1)
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        shelf.post(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible, "A repeat updates the visible pill in place")
        messages.messenger(for: .battery).post(IslandNotice(key: "power", title: "Power connected"))
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        XCTAssertEqual(messages.currentNotice?.moduleID, .shelf,
                       "Battery's notice could not appear in the open panel, so it does not cut Shelf's short")
        await clock.advance(by: IslandMessageCenter.defaultDuration - IslandMessageCenter.handoffDuration)
        XCTAssertEqual(messages.currentNotice?.moduleID, .battery)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(controller.panel.isVisible, "Another module's notice waits for the panel to close")
    }

    func testPlacementKeepsTenPointGapAtEveryIslandHeight() {
        for height in [CGFloat(338), 448, 700] {
            let island = CGRect(x: 300, y: 1000 - height, width: 492, height: height)
            for pillHeight in [CGFloat(34), 48, 72] {
                let frame = IslandNoticePlacement.frame(below: island, pillSize: CGSize(width: 300, height: pillHeight))
                let pill = frame.insetBy(dx: IslandNoticePlacement.shadowInset, dy: IslandNoticePlacement.shadowInset)
                XCTAssertEqual(pill.midX, island.midX)
                XCTAssertEqual(island.minY - pill.maxY, IslandNoticePlacement.gap)
                XCTAssertFalse(pill.intersects(island))
            }
        }
    }

    func testPinnedNoticeIsImmediateAndHasIndependentLifetime() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        coordinator.show(module: .shelf, pinned: true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let messages = makeMessages()
        let shelf = messages.messenger(for: .shelf)
        let target = DropTargetState()
        let anchor = NSWindow(contentRect: layout.expandedFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        let islandFrame = anchor.frame
        defer { anchor.close() }
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings, dropTarget: target)
        defer { controller.stop() }
        shelf.post(.reconnected)
        try await Task.sleep(for: .milliseconds(300))
        let pill = controller.panel
        XCTAssertNil(pill.parent)
        XCTAssertTrue(pill.isVisible)
        XCTAssertTrue(pill.ignoresMouseEvents)
        XCTAssertEqual(anchor.frame, islandFrame, "Feedback must not resize the Island")
        let firstPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(anchor.frame.minY - firstPill.maxY, 10, accuracy: 1)

        var tallerFrame = islandFrame.offsetBy(dx: 20, dy: -60)
        tallerFrame.size.height += 60
        anchor.setFrame(tallerFrame, display: true)
        try await Task.sleep(for: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(400))
        let movedPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(movedPill.midX, anchor.frame.midX, accuracy: 1)
        XCTAssertEqual(anchor.frame.minY - movedPill.maxY, 10, accuracy: 1)
        shelf.post(.receivedAwaitingRecovery)
        XCTAssertEqual(messages.waitingNotices.count, 1, "A notice with a button waits behind the plain one")
        await clock.advance(by: IslandMessageCenter.handoffDuration)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(messages.currentNotice?.notice, ShelfNotice.receivedAwaitingRecovery.notice)
        let recoveryFrame = try XCTUnwrap(controller.interactionFrame)
        controller.updatePointer(at: CGPoint(x: recoveryFrame.midX, y: recoveryFrame.midY))
        XCTAssertFalse(pill.ignoresMouseEvents)
        controller.updatePointer(at: CGPoint(x: recoveryFrame.midX, y: recoveryFrame.maxY + 5))
        XCTAssertTrue(pill.ignoresMouseEvents, "Shadow canvas must pass clicks to underlying windows")
        XCTAssertTrue(anchor.childWindows?.isEmpty ?? true)

        target.isTargeted = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible)
        XCTAssertNil(controller.interactionFrame)
        XCTAssertFalse(messages.isNoticeClockRunning, "Drag time does not count")
        target.hasDuplicateFiles = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible, "Duplicate feedback must wait for release")
        XCTAssertTrue(pill.ignoresMouseEvents, "Feedback must not intercept a drop")
        target.hasDuplicateFiles = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible, "A nonduplicate drag must clear duplicate feedback")
        shelf.withdrawNotice(ShelfNotice.receivedAwaitingRecovery.rawValue)
        shelf.post(.alreadyOnShelf)
        target.isTargeted = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pill.isVisible)
        coordinator.collapse()
        anchor.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pill.isVisible, "An already-visible pill stays visible during closing")
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pill.isVisible, "Feedback appears once the closing animation finishes")
        XCTAssertNil(pill.parent)
        XCTAssertEqual(try XCTUnwrap(controller.interactionFrame).maxY,
                       layout.closedNoticeAnchor.minY - 10, accuracy: 1)
        shelf.post(.removed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pill.isVisible, "A new completion notice must also work while the Island is hidden")
        XCTAssertEqual(messages.currentNotice?.notice, ShelfNotice.removed.notice)
        await clock.advance(by: IslandMessageCenter.defaultDuration)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible, "Only the notice's own expiry should dismiss it")
        coordinator.show(module: .shelf)
        anchor.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(pill.isVisible, "Reopening must not replay an expired notice")
    }

    private func makeCollapsedFixture(_ context: PreviewContext) throws
        -> (SettingsStore, IslandActivityCoordinator, NSWindow, IslandGeometryResolver.Layout) {
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        let anchor = NSWindow(contentRect: layout.notchFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        return (settings, coordinator, anchor, layout)
    }

    func testHoveringActionablePillStopsClockAndLeavingResumesIt() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let (settings, coordinator, anchor, _) = try makeCollapsedFixture(context)
        defer { anchor.close() }
        let messages = makeMessages()
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        let shelf = messages.messenger(for: .shelf)

        shelf.post(.moveRecoveryNeedsAttention)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(messages.isNoticeClockRunning)
        await clock.advance(by: 2)
        let frame = try XCTUnwrap(controller.interactionFrame)
        controller.updatePointer(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertFalse(messages.isNoticeClockRunning, "Resting on a pill with a button holds it")
        await clock.advance(by: 60)
        XCTAssertNotNil(messages.currentNotice)
        controller.updatePointer(at: CGPoint(x: frame.midX, y: frame.maxY + 40))
        XCTAssertTrue(messages.isNoticeClockRunning)
        await clock.advance(by: 5.9)
        XCTAssertNotNil(messages.currentNotice, "Leaving resumes the remaining time, not a new one")
        await clock.advance(by: 0.1)
        XCTAssertNil(messages.currentNotice)

        shelf.post(.removed)
        try await Task.sleep(for: .milliseconds(300))
        let plainFrame = try XCTUnwrap(controller.interactionFrame)
        controller.updatePointer(at: CGPoint(x: plainFrame.midX, y: plainFrame.midY))
        XCTAssertTrue(messages.isNoticeClockRunning, "A pill without a button is not held")
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
    }

    func testStartupNoticeWaitsForThePanelInsteadOfExpiring() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let (settings, coordinator, anchor, _) = try makeCollapsedFixture(context)
        defer { anchor.close() }
        let messages = makeMessages()
        messages.messenger(for: .shelf).post(.moveRecoveryNeedsAttention)
        await clock.advance(by: 60)
        XCTAssertEqual(messages.currentNotice?.notice, ShelfNotice.moveRecoveryNeedsAttention.notice,
                       "No presenter yet, so no time counts")

        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible)
        await clock.advance(by: IslandMessageCenter.actionDuration - 0.1)
        XCTAssertNotNil(messages.currentNotice)
        await clock.advance(by: 0.1)
        XCTAssertNil(messages.currentNotice)
    }

    func testShownModuleNoticeAppearsInUnpinnedPanel() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let anchor = NSWindow(contentRect: layout.expandedFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let messages = makeMessages()
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }

        messages.messenger(for: .shelf).post(.removed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible, "The panel shows Shelf, so its notice appears right away")
        XCTAssertTrue(messages.isNoticeClockRunning)
    }

    /// The controller feeds the center the module the panel shows, so the center's queue and
    /// the presentation agree: the shown module's notice is not stuck behind a held one, and
    /// a raised status of the shown module shows no pill.
    func testControllerFeedsTheShownModuleToTheQueue() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        coordinator.show(module: .timer)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let anchor = NSWindow(contentRect: layout.expandedFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let messages = makeMessages()
        let controller = makeController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(messages.shownModule, .timer)
        XCTAssertTrue(messages.othersWaitForShownModule)

        messages.messenger(for: .battery).post(IslandNotice(key: "power", title: "Power connected"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.panel.isVisible, "Battery waits for the panel to close")
        messages.messenger(for: .timer).post(IslandNotice(key: "done", title: "Done"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(messages.currentNotice?.moduleID, .timer)
        XCTAssertTrue(controller.panel.isVisible, "Timer's notice goes ahead and appears")
        XCTAssertEqual(messages.waitingNotices.map(\.moduleID), [.battery])

        messages.moduleDidStart(.timer)
        messages.messenger(for: .timer).setStatus(.init(key: "finished", title: "Timer finished",
                                                        systemImage: "timer", tone: .warning))
        XCTAssertFalse(messages.waitingNotices.contains { $0.raisedStatusKey != nil },
                       "The panel shows Timer, so its raised status shows no pill")

        coordinator.setPinned(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(messages.othersWaitForShownModule)
        coordinator.collapse()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(messages.shownModule)
    }

    func testButtonTitleComesFromTheAction() {
        for action in [IslandNoticeAction.openStorageRecovery, .openModule(.timer)] {
            let pill = IslandNoticePill(notice: IslandNotice(key: "a", title: "Something happened", action: action),
                                        onPerformAction: { _ in })
            XCTAssertEqual(pill.actionTitle, action.title)
        }
        XCTAssertNil(IslandNoticePill(notice: IslandNotice(key: "a", title: "Plain"), onPerformAction: { _ in }).actionTitle)
        XCTAssertNil(IslandNoticePill(notice: ShelfNotice.moveRecoveryNeedsAttention.notice).actionTitle,
                     "Without a handler the pill shows no button")
    }
}
