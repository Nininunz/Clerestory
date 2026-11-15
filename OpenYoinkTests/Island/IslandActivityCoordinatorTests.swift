import XCTest
@testable import OpenYoink

@MainActor
final class IslandActivityCoordinatorTests: XCTestCase {
    func testSwipeCompletionCommitsOnceAndCancellationReturns() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .shelf)
        let revision = coordinator.shortcutNavigationRevision
        coordinator.shortcutSwipeTarget = .timer
        coordinator.shortcutSwipeOffset = -200
        coordinator.completeShortcutSwipe(target: .timer, revision: revision)
        XCTAssertEqual(coordinator.selectedModule, .timer)
        XCTAssertEqual(coordinator.shortcutSwipeOffset, 0)
        XCTAssertNil(coordinator.shortcutSwipeTarget)
        coordinator.completeShortcutSwipe(target: .battery, revision: revision)
        XCTAssertEqual(coordinator.selectedModule, .timer)

        coordinator.shortcutSwipeOffset = 20
        coordinator.shortcutSwipeTarget = .shelf
        coordinator.completeShortcutSwipe(target: nil, revision: coordinator.shortcutNavigationRevision)
        XCTAssertEqual(coordinator.selectedModule, .timer)
        XCTAssertEqual(coordinator.shortcutSwipeOffset, 0)
        XCTAssertNil(coordinator.shortcutSwipeTarget)
    }

    func testSwipeCompletionCannotOverrideClickAwayAndBackOrCollapseAndReopen() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .shelf)
        let beforeClick = coordinator.shortcutNavigationRevision
        coordinator.selectedModule = .quickSettings
        coordinator.selectedModule = .shelf
        coordinator.completeShortcutSwipe(target: .timer, revision: beforeClick)
        XCTAssertEqual(coordinator.selectedModule, .shelf)

        let beforeSamePageClick = coordinator.shortcutNavigationRevision
        coordinator.shortcutSwipeOffset = -100
        coordinator.shortcutSwipeTarget = .timer
        coordinator.selectedModule = .shelf
        coordinator.completeShortcutSwipe(target: .timer, revision: beforeSamePageClick)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.shortcutSwipeOffset, 0)
        XCTAssertNil(coordinator.shortcutSwipeTarget)

        let beforeCollapse = coordinator.shortcutNavigationRevision
        coordinator.shortcutSwipeOffset = -100
        coordinator.shortcutSwipeTarget = .timer
        coordinator.collapse()
        XCTAssertEqual(coordinator.shortcutSwipeOffset, 0)
        XCTAssertNil(coordinator.shortcutSwipeTarget)
        coordinator.show(module: .shelf)
        coordinator.completeShortcutSwipe(target: .timer, revision: beforeCollapse)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
    }

    func testShortcutOrderSkipsDisabledPagesAndKeepsSettingsLast() {
        let pinned: [IslandModuleID] = [.battery, .timer, .shelf]
        func target(_ current: IslandModuleID, _ step: Int) -> IslandModuleID? {
            IslandShortcutSwipe.target(current: current, step: step, pinned: pinned,
                                       enabled: { $0 != .timer })
        }
        XCTAssertNil(target(.battery, -1))
        XCTAssertEqual(target(.battery, 1), .shelf)
        XCTAssertEqual(target(.shelf, 1), .quickSettings)
        XCTAssertEqual(target(.quickSettings, -1), .shelf)
        XCTAssertNil(target(.quickSettings, 1))
        XCTAssertEqual(IslandShortcutSwipe.target(current: .shelf, step: 1, pinned: [],
                                                 enabled: { _ in true }), .quickSettings)
    }

    func testShortDragCancellationAndEdgeCannotCommitButFlickCan() {
        XCTAssertFalse(IslandShortcutSwipe.shouldCommit(projected: -30, direction: 1, width: 464, hasTarget: true, cancelled: false))
        XCTAssertTrue(IslandShortcutSwipe.shouldCommit(projected: -150, direction: 1, width: 464, hasTarget: true, cancelled: false))
        XCTAssertFalse(IslandShortcutSwipe.shouldCommit(projected: -150, direction: 1, width: 464, hasTarget: true, cancelled: true))
        XCTAssertFalse(IslandShortcutSwipe.shouldCommit(projected: -150, direction: 1, width: 464, hasTarget: false, cancelled: false))
        XCTAssertFalse(IslandShortcutSwipe.shouldCommit(projected: 150, direction: 1, width: 464, hasTarget: true, cancelled: false))
    }

    func testQuickSettingsSurvivesSettingsEditsAndYieldsToAnotherShortcut() throws {
        let name = "QuickSettingsNavigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let registry = IslandModuleRegistry()
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .quickSettings)
        settings.islandTimerEnabled = false
        registry.apply(settings: settings)
        XCTAssertTrue(registry.isEnabled(coordinator.selectedModule))
        XCTAssertEqual(coordinator.selectedModule, .quickSettings)
        coordinator.selectedModule = .shelf
        XCTAssertEqual(coordinator.selectedModule, .shelf)
    }

    func testQuickFlickProjectsFartherButHoldingRemovesMomentum() {
        var swipe = IslandShortcutSwipe()
        _ = swipe.sample(dx: -15, dy: 0, began: true, momentum: false, timestamp: 1)
        _ = swipe.sample(dx: -20, dy: 0, began: false, momentum: false, timestamp: 1.016)
        XCTAssertLessThan(swipe.projectedTranslation(at: 1.03), -84)
        XCTAssertEqual(swipe.projectedTranslation(at: 1.3), -35)
    }

    func testShortcutSwipeTracksFingerDistanceAndIgnoresMomentum() {
        var swipe = IslandShortcutSwipe()
        XCTAssertEqual(swipe.sample(dx: -20, dy: 1, began: true, momentum: false), .drag(-20))
        XCTAssertEqual(swipe.sample(dx: -30, dy: 1, began: false, momentum: false), .drag(-50))
        XCTAssertEqual(swipe.sample(dx: -80, dy: 0, began: false, momentum: false), .drag(-130))
        XCTAssertEqual(swipe.sample(dx: -80, dy: 0, began: false, momentum: true), .consumed)
        XCTAssertEqual(swipe.sample(dx: 50, dy: 0, began: true, momentum: false), .drag(50))
    }

    func testVerticalScrollNeverTurnsIntoShortcutSwipe() {
        var swipe = IslandShortcutSwipe()
        XCTAssertEqual(swipe.sample(dx: 2, dy: 20, began: true, momentum: false), .ignored)
        XCTAssertEqual(swipe.sample(dx: 80, dy: 2, began: false, momentum: false), .ignored)
        XCTAssertEqual(swipe.sample(dx: 80, dy: 0, began: false, momentum: true), .ignored)
    }

    func testRegistryCanDisableShelfWithoutDisablingIslandModules() throws {
        let suiteName = "IslandModuleRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.islandShelfEnabled = false
        settings.islandTimerEnabled = true
        settings.islandBatteryEnabled = true

        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)

        XCTAssertFalse(registry.isEnabled(.shelf))
        XCTAssertTrue(registry.isEnabled(.transfers))
        XCTAssertTrue(registry.isEnabled(.timer))
        XCTAssertTrue(registry.isEnabled(.battery))
    }

    func testPriorityPicksDragBeforeTransferAndTimer() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer, priority: .timerFinished))
        coordinator.publish(activity(id: "transfer", module: .transfers, priority: .transfer))
        coordinator.publish(activity(id: "drag", module: .shelf, priority: .userDrag))
        XCTAssertEqual(coordinator.primaryActivity()?.id, "drag")
        coordinator.removeActivity(id: "drag")
        XCTAssertEqual(coordinator.primaryActivity()?.id, "transfer")
    }

    func testAdvisoryAlertYieldsToNowPlayingAfterItsSpotlight() {
        let coordinator = IslandActivityCoordinator()
        let start = Date(timeIntervalSince1970: 1_000)
        coordinator.publish(activity(id: "media", module: .media, priority: .nowPlaying), at: start)
        coordinator.publish(activity(id: "ai", module: .aiUsage, priority: .systemWarning), at: start)

        XCTAssertEqual(coordinator.primaryActivity(at: start.addingTimeInterval(1))?.id, "ai")
        let after = start.addingTimeInterval(IslandActivityCoordinator.advisorySpotlightDuration + 1)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "media")

        // Republishing fresh numbers must not restart the spotlight.
        coordinator.publish(activity(id: "ai", module: .aiUsage, priority: .systemWarning), at: after)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "media")

        // Without media, the alert keeps the compact Island.
        coordinator.removeActivity(id: "media")
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "ai")
    }

    func testCriticalActivitiesStillOutrankNowPlaying() {
        let coordinator = IslandActivityCoordinator()
        let start = Date(timeIntervalSince1970: 1_000)
        coordinator.publish(activity(id: "media", module: .media, priority: .nowPlaying), at: start)
        coordinator.publish(activity(id: "battery", module: .battery, priority: .criticalBattery), at: start)
        let after = start.addingTimeInterval(IslandActivityCoordinator.advisorySpotlightDuration + 60)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "battery")
    }

    func testSelectedModuleSummaryDoesNotOverrideAnotherModule() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer,
                                     priority: .selectedModule))
        XCTAssertNil(coordinator.primaryActivity())
        coordinator.selectedModule = .timer
        XCTAssertEqual(coordinator.primaryActivity()?.id, "timer")
    }

    func testCompactActivityDoesNotDependOnExpandedSelection() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer,
                                     priority: .selectedModule))
        XCTAssertEqual(coordinator.compactPrimaryActivity()?.id, "timer")
        coordinator.selectedModule = .media
        XCTAssertEqual(coordinator.compactPrimaryActivity()?.id, "timer")
        XCTAssertNil(coordinator.primaryActivity())
    }

    func testCompactWingsFollowManualSelection() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .battery]
        XCTAssertEqual(IslandCompactDisplay.selected(.battery, enabled: enabled), .battery)
        XCTAssertEqual(IslandCompactDisplay.selected(.timer, enabled: enabled), .timer)
        XCTAssertEqual(IslandCompactDisplay.selected(.shelf, enabled: enabled), .shelf)
    }

    func testExpiredActivityIsIgnoredAndPruned() {
        let coordinator = IslandActivityCoordinator()
        let now = Date(timeIntervalSince1970: 100)
        coordinator.publish(.init(id: "expired", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt", expiresAt: now.addingTimeInterval(-1)))
        XCTAssertNil(coordinator.primaryActivity(at: now))
        coordinator.pruneExpired(at: now)
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testExpiringActivityPrunesItselfWithoutPolling() async throws {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(.init(id: "brief", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt",
                                  expiresAt: Date().addingTimeInterval(0.02)))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testCancelledDragRestoresPreviousModuleAndState() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer, pinned: true)
        coordinator.beginDrag()
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
        coordinator.endDrag(imported: false)
        XCTAssertEqual(coordinator.selectedModule, .timer)
        XCTAssertEqual(coordinator.surfaceState, .pinned)
    }

    func testSuccessfulDropStaysExpandedOnShelf() {
        let coordinator = IslandActivityCoordinator()
        coordinator.collapse()
        coordinator.beginDrag()
        coordinator.endDrag(imported: true)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testDeliberateCollapseSuppressesHoverRevealUntilPointerExits() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer)

        coordinator.collapse()
        coordinator.setPointerHovering(true)

        XCTAssertEqual(coordinator.surfaceState, .compact)
        XCTAssertFalse(coordinator.canRevealOnHover)

        coordinator.setPointerHovering(false)
        XCTAssertTrue(coordinator.canRevealOnHover)
    }

    func testProgrammaticCollapseCanLeaveHoverRevealAvailable() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .shelf)

        coordinator.collapse(suppressHoverUntilPointerExit: false)

        XCTAssertEqual(coordinator.surfaceState, .compact)
        XCTAssertTrue(coordinator.canRevealOnHover)
    }

    func testExplicitShowClearsHoverRevealSuppression() {
        let coordinator = IslandActivityCoordinator()
        coordinator.collapse()
        XCTAssertFalse(coordinator.canRevealOnHover)

        coordinator.show(module: .media)

        XCTAssertTrue(coordinator.canRevealOnHover)
        XCTAssertEqual(coordinator.selectedModule, .media)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testHoverPreviewCancelsDwellWhenPointerLeaves() {
        var preview = IslandHoverPreviewStateMachine()
        XCTAssertEqual(preview.handle(.entered), [.scheduleDwell])
        XCTAssertEqual(preview.handle(.left), [.cancelDwell])
        XCTAssertEqual(preview.handle(.dwellElapsed), [])
        XCTAssertEqual(preview.phase, .idle)
    }

    func testHoverPreviewExitGraceAndPinPromotion() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        XCTAssertEqual(preview.handle(.dwellElapsed), [.showPreview])
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.entered), [.cancelExit])
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.committed), [.cancelExit, .commitPreview])
        XCTAssertEqual(preview.handle(.exitElapsed), [])
        XCTAssertEqual(preview.phase, .idle)
    }

    func testInteractionInsideHoverPreviewDoesNotPreventAutoClose() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        XCTAssertEqual(preview.handle(.dwellElapsed), [.showPreview])
        XCTAssertEqual(preview.handle(.entered), [])
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.entered), [.cancelExit])
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.exitElapsed), [.dismissPreview])
        XCTAssertEqual(preview.phase, .idle)
    }

    func testHoverPreviewDismissesAfterExitGrace() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        _ = preview.handle(.dwellElapsed)
        _ = preview.handle(.left)
        XCTAssertEqual(preview.handle(.exitElapsed), [.dismissPreview])
        XCTAssertEqual(preview.phase, .idle)
    }

    func testHoverPreviewResetCancelsExitAndDismisses() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        _ = preview.handle(.dwellElapsed)
        _ = preview.handle(.left)
        XCTAssertEqual(preview.handle(.reset), [.cancelExit, .dismissPreview])
        XCTAssertEqual(preview.phase, .idle)
    }

    func testSurfaceWillChangeCallbackRunsBeforeObservableMutation() {
        let coordinator = IslandActivityCoordinator()
        var callbackStates: [(IslandSurfaceState, IslandSurfaceState, IslandSurfaceState)] = []
        coordinator.onSurfaceStateWillChange = { oldState, newState in
            callbackStates.append((oldState, newState, coordinator.surfaceState))
        }

        coordinator.show(module: .media)

        XCTAssertEqual(callbackStates.count, 1)
        XCTAssertEqual(callbackStates.first?.0, .compact)
        XCTAssertEqual(callbackStates.first?.1, .expanded)
        XCTAssertEqual(callbackStates.first?.2, .compact)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testCollapseWaitsForItsActualAnimationCompletion() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show()
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        coordinator.collapse()
        var completions = 0
        coordinator.onSurfaceAnimationCompleted = { completions += 1 }
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        let collapseID = coordinator.surfaceTransitionID
        coordinator.publish(activity(id: "sample", module: .system, priority: .selectedModule))
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(coordinator.surfaceTransitionID, collapseID)
        coordinator.completeSurfaceTransition(collapseID)
        coordinator.completeSurfaceTransition(collapseID)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(completions, 1)
    }

    func testOldCollapseCompletionCannotFinishANewerCollapse() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show()
        coordinator.collapse()
        let oldCollapseID = coordinator.surfaceTransitionID
        coordinator.show()
        let reopenID = coordinator.surfaceTransitionID
        coordinator.collapse()
        let currentID = coordinator.surfaceTransitionID
        coordinator.completeSurfaceTransition(oldCollapseID)
        coordinator.completeSurfaceTransition(reopenID)
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(coordinator.surfaceState, .compact)
        coordinator.completeSurfaceTransition(currentID)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)
    }

    private func activity(id: String, module: IslandModuleID,
                          priority: IslandActivityPriority) -> IslandActivity {
        .init(id: id, moduleID: module, priority: priority,
              title: id, detail: nil, systemImage: "circle", expiresAt: nil)
    }
}
