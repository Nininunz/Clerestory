import AppKit
import XCTest
@testable import Clerestory

@MainActor
final class IslandNoticePanelTests: XCTestCase {
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
        let messages = IslandMessageCenter()
        let shelf = messages.messenger(for: .shelf)
        let anchor = NSWindow(contentRect: layout.expandedFrame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = IslandNoticePanelController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings, dropTarget: DropTargetState())
        defer { controller.stop() }
        shelf.post(.alreadyOnShelf)
        try await Task.sleep(for: .seconds(IslandMessageCenter.displayDuration + 0.3))
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(messages.current?.notice, ShelfNotice.alreadyOnShelf.notice)
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
        try await Task.sleep(for: .seconds(IslandMessageCenter.displayDuration + 0.3))
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertNil(messages.current)
    }

    func testReopeningPushesVisiblePillBelowExpandedIsland() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = try liveLayout()
        coordinator.currentLayout = layout
        let messages = IslandMessageCenter()
        let shelf = messages.messenger(for: .shelf)
        let anchor = NSWindow(contentRect: layout.notchFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = IslandNoticePanelController(anchor: anchor, messages: messages,
            coordinator: coordinator, settings: settings, dropTarget: DropTargetState())
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
        XCTAssertFalse(controller.panel.isVisible, "A new identical notice still waits for its own initial close")
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
        let messages = IslandMessageCenter()
        let shelf = messages.messenger(for: .shelf)
        let target = DropTargetState()
        let anchor = NSWindow(contentRect: layout.expandedFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        let islandFrame = anchor.frame
        defer { anchor.close() }
        let controller = IslandNoticePanelController(anchor: anchor, messages: messages,
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
        try await Task.sleep(for: .milliseconds(100))
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
        target.hasDuplicateFiles = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible, "Duplicate feedback must wait for release")
        XCTAssertTrue(pill.ignoresMouseEvents, "Feedback must not intercept a drop")
        target.hasDuplicateFiles = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(pill.isVisible, "A nonduplicate drag must clear duplicate feedback")
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
        shelf.post(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pill.isVisible, "A new completion notice must also work while the Island is hidden")
        try await Task.sleep(for: .seconds(IslandMessageCenter.displayDuration + 0.3))
        XCTAssertFalse(pill.isVisible, "Only the notice's own expiry should dismiss it")
        coordinator.show(module: .shelf)
        anchor.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(pill.isVisible, "Reopening must not replay an expired notice")
    }
}
