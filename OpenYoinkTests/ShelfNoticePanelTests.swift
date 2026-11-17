import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfNoticePanelTests: XCTestCase {
    func testUnpinnedNoticeWaitsWithoutExpiringAndIgnoresStaleCloseCompletion() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        coordinator.currentLayout = IslandGeometryResolver.resolve(screen: ModulePreviewHost.screen)
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let notices = ShelfNoticeModel()
        let anchor = NSWindow(contentRect: CGRect(x: 100, y: 400, width: 492, height: 338),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = ShelfNoticePanelController(anchor: anchor, notices: notices,
            coordinator: coordinator, settings: settings, dropTarget: DropTargetState(), onRecovery: { _ in })
        defer { controller.stop() }
        notices.show(.alreadyOnShelf)
        try await Task.sleep(for: .seconds(ShelfNoticeModel.displayDuration + 0.3))
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(notices.current, ShelfNoticeMessage.alreadyOnShelf.presentation)
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
        try await Task.sleep(for: .seconds(ShelfNoticeModel.displayDuration + 0.3))
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertNil(notices.current)
    }

    func testReopeningPushesVisibleToastBelowExpandedIsland() async throws {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let settings = context.settings()
        settings.islandEnabled = true
        let coordinator = IslandActivityCoordinator()
        let layout = IslandGeometryResolver.resolve(screen: ModulePreviewHost.screen)
        coordinator.currentLayout = layout
        let notices = ShelfNoticeModel()
        let anchor = NSWindow(contentRect: layout.compactFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = ShelfNoticePanelController(anchor: anchor, notices: notices,
            coordinator: coordinator, settings: settings, dropTarget: DropTargetState(), onRecovery: { _ in })
        defer { controller.stop() }
        notices.show(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.panel.isVisible)
        let compactPill = try XCTUnwrap(controller.interactionFrame)
        anchor.setFrame(layout.expandedFrame, display: true)
        coordinator.show(module: .shelf)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.panel.isVisible, "Reopening must not hide a displayed toast")
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(450))
        let expandedPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(expandedPill.maxY, layout.expandedFrame.minY - 10, accuracy: 1)
        XCTAssertLessThan(expandedPill.maxY, compactPill.maxY)
        XCTAssertEqual(expandedPill.midX, layout.expandedFrame.midX, accuracy: 1)
        coordinator.collapse()
        anchor.setFrame(layout.compactFrame, display: true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(try XCTUnwrap(controller.interactionFrame).maxY, compactPill.maxY, accuracy: 1)
        coordinator.show(module: .shelf)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        notices.show(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(controller.panel.isVisible, "A new identical notice still waits for its own initial close")
    }

    func testPlacementKeepsTenPointGapAtEveryIslandHeight() {
        for height in [CGFloat(338), 448, 700] {
            let island = CGRect(x: 300, y: 1000 - height, width: 492, height: height)
            for pillHeight in [CGFloat(34), 48, 72] {
                let frame = ShelfNoticePlacement.frame(below: island, pillSize: CGSize(width: 300, height: pillHeight))
                let pill = frame.insetBy(dx: ShelfNoticePlacement.shadowInset, dy: ShelfNoticePlacement.shadowInset)
                XCTAssertEqual(pill.midX, island.midX)
                XCTAssertEqual(island.minY - pill.maxY, ShelfNoticePlacement.gap)
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
        coordinator.show(module: .shelf, pinned: true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let notices = ShelfNoticeModel()
        let target = DropTargetState()
        let islandFrame = CGRect(x: 100, y: 400, width: 492, height: 338)
        let anchor = NSWindow(contentRect: islandFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFront(nil)
        defer { anchor.close() }
        let controller = ShelfNoticePanelController(anchor: anchor, notices: notices,
            coordinator: coordinator, settings: settings, dropTarget: target, onRecovery: { _ in })
        defer { controller.stop() }
        notices.show(.reconnected)
        try await Task.sleep(for: .milliseconds(300))
        let toast = controller.panel
        XCTAssertNil(toast.parent)
        XCTAssertTrue(toast.isVisible)
        XCTAssertTrue(toast.ignoresMouseEvents)
        XCTAssertEqual(anchor.frame, islandFrame, "Feedback must not resize the Island")
        let firstPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(anchor.frame.minY - firstPill.maxY, 10, accuracy: 1)

        anchor.setFrame(CGRect(x: 200, y: 250, width: 492, height: 488), display: true)
        try await Task.sleep(for: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(400))
        let movedPill = try XCTUnwrap(controller.interactionFrame)
        XCTAssertEqual(movedPill.midX, anchor.frame.midX, accuracy: 1)
        XCTAssertEqual(anchor.frame.minY - movedPill.maxY, 10, accuracy: 1)
        notices.show(.receivedAwaitingRecovery)
        try await Task.sleep(for: .milliseconds(100))
        let recoveryFrame = try XCTUnwrap(controller.interactionFrame)
        controller.updatePointer(at: CGPoint(x: recoveryFrame.midX, y: recoveryFrame.midY))
        XCTAssertFalse(toast.ignoresMouseEvents)
        controller.updatePointer(at: CGPoint(x: recoveryFrame.midX, y: recoveryFrame.maxY + 5))
        XCTAssertTrue(toast.ignoresMouseEvents, "Shadow canvas must pass clicks to underlying windows")
        XCTAssertTrue(anchor.childWindows?.isEmpty ?? true)

        target.isTargeted = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(toast.isVisible)
        XCTAssertNil(controller.interactionFrame)
        target.hasDuplicateFiles = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(toast.isVisible, "Duplicate feedback must wait for release")
        XCTAssertTrue(toast.ignoresMouseEvents, "Feedback must not intercept a drop")
        target.hasDuplicateFiles = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(toast.isVisible, "A nonduplicate drag must clear duplicate feedback")
        notices.show(.alreadyOnShelf)
        target.isTargeted = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toast.isVisible)
        coordinator.currentLayout = IslandGeometryResolver.resolve(screen: ModulePreviewHost.screen)
        coordinator.collapse()
        anchor.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toast.isVisible, "An already-visible toast stays visible during closing")
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toast.isVisible, "Feedback appears once the closing animation finishes")
        XCTAssertNil(toast.parent)
        let compactFrame = try XCTUnwrap(coordinator.currentLayout?.compactFrame)
        XCTAssertEqual(try XCTUnwrap(controller.interactionFrame).maxY, compactFrame.minY - 10, accuracy: 1)
        notices.show(.alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toast.isVisible, "A new completion notice must also work while the Island is hidden")
        try await Task.sleep(for: .seconds(ShelfNoticeModel.displayDuration + 0.3))
        XCTAssertFalse(toast.isVisible, "Only the notice's own expiry should dismiss it")
        coordinator.show(module: .shelf)
        anchor.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(toast.isVisible, "Reopening must not replay an expired notice")
    }
}
