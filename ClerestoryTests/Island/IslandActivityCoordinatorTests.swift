import XCTest
@testable import Clerestory

@MainActor
final class IslandActivityCoordinatorTests: XCTestCase {
    func testDropFeedbackClosesTransientPanelButKeepsPinnedOrigin() {
        for pinned in [false, true] {
            let coordinator = IslandActivityCoordinator()
            if pinned { coordinator.show(module: .shelf, pinned: true) }
            coordinator.beginDrag()
            coordinator.endDrag(imported: true, hasPendingNotice: true)
            XCTAssertEqual(coordinator.surfaceState, pinned ? .pinned : .collapsed)
        }
    }

    func testEndDragReportsOnlyADragOpenedPanelThatADropKeepsOpen() {
        let opened = IslandActivityCoordinator()
        opened.beginDrag()
        XCTAssertTrue(opened.endDrag(imported: true), "The drag opened it and the drop keeps it open")
        XCTAssertEqual(opened.surfaceState, .expanded)

        let userOpened = IslandActivityCoordinator()
        userOpened.show(module: .shelf, pinned: false)
        userOpened.beginDrag()
        XCTAssertFalse(userOpened.endDrag(imported: true), "It was already open before the drag")

        let pinned = IslandActivityCoordinator()
        pinned.show(module: .shelf, pinned: true)
        pinned.beginDrag()
        XCTAssertFalse(pinned.endDrag(imported: true))

        let empty = IslandActivityCoordinator()
        empty.beginDrag()
        XCTAssertFalse(empty.endDrag(imported: false), "Nothing landed, so it closes")
        XCTAssertEqual(empty.surfaceState, .collapsed)
    }

    func testNotchActivationPreservesPinWhileSwitchingModules() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .quickSettings, pinned: true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let transition = coordinator.surfaceTransitionID

        coordinator.showFromNotch(module: .shelf)

        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .pinned)
        XCTAssertEqual(coordinator.surfaceTransitionID, transition)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)

        coordinator.setPinned(false)
        coordinator.showFromNotch(module: .quickSettings)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
        coordinator.collapse()
        coordinator.showFromNotch(module: .shelf)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded, "Reopening must not restore a released pin")
    }

    func testExtendedModuleChoicesPersistIndependentlyAcrossRestart() throws {
        let suite = "Clerestory.ExtensionPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = IslandModuleRegistry.quickSettingsDescriptor
        let second = IslandModuleDescriptor(id: .timer, title: "Timer", systemImage: "timer",
            order: 1, isCore: false, supportsExtendedHeight: true)
        let original = IslandActivityCoordinator(defaults: defaults)
        original.setModuleExtended(true, descriptor: first)
        original.setModuleExtended(true, descriptor: second)
        let restored = IslandActivityCoordinator(defaults: defaults)
        XCTAssertTrue(restored.isModuleExtended(first))
        XCTAssertTrue(restored.isModuleExtended(second))
        restored.setModuleExtended(false, descriptor: first)
        let restarted = IslandActivityCoordinator(defaults: defaults)
        XCTAssertFalse(restarted.isModuleExtended(first))
        XCTAssertTrue(restarted.isModuleExtended(second))
        XCTAssertTrue(restarted.moduleContentHeights.isEmpty,
                      "Content heights must be remeasured for the current display")
        XCTAssertFalse(IslandActivityCoordinator().isModuleExtended(second))
    }

    func testReentryGraceRestoresLastModuleUntilDeadlineAndSkipsDisabledModules() {
        let coordinator = IslandActivityCoordinator()
        coordinator.selectedModule = .quickSettings
        coordinator.quickSettingsShowsNotch = true
        coordinator.rememberDeparture(at: 100)
        coordinator.selectedModule = .shelf
        XCTAssertEqual(coordinator.reentryModule(at: 102.99, isEnabled: { _ in true }), .quickSettings)
        XCTAssertNil(coordinator.reentryModule(at: 103, isEnabled: { _ in true }))
        XCTAssertNil(coordinator.reentryModule(at: 101, isEnabled: { _ in false }))
        XCTAssertTrue(coordinator.quickSettingsShowsNotch)
        coordinator.selectedModule = .timer
        coordinator.rememberDeparture(at: 110)
        XCTAssertEqual(coordinator.reentryModule(at: 111, isEnabled: { _ in true }), .timer)
    }

    func testCollapseRecordsDepartedModuleBeforeSelectionRestoration() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .quickSettings)
        coordinator.collapse()
        coordinator.selectedModule = .shelf
        XCTAssertEqual(coordinator.reentryModule(isEnabled: { _ in true }), .quickSettings)
        coordinator.collapse()
        XCTAssertEqual(coordinator.reentryModule(isEnabled: { _ in true }), .quickSettings)
    }

    func testContentSizedExtensionIsOptInAndIndependentPerModule() {
        let coordinator = IslandActivityCoordinator()
        let first = IslandModuleDescriptor(id: .quickSettings, title: "First", systemImage: "gear",
            order: 0, isCore: true, supportsExtendedHeight: true)
        let second = IslandModuleDescriptor(id: .timer, title: "Second", systemImage: "timer",
            order: 1, isCore: false, supportsExtendedHeight: true)
        let unsupported = IslandModuleDescriptor(id: .battery, title: "Battery", systemImage: "battery",
            order: 2, isCore: false)
        coordinator.recordModuleContentHeight(482.2, descriptor: first)
        coordinator.recordModuleContentHeight(610, descriptor: second)
        coordinator.setModuleExtended(true, descriptor: first)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: first), 483)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: second), 330)
        coordinator.selectedModule = .timer
        coordinator.setModuleExtended(true, descriptor: second)
        coordinator.setModuleExtended(false, descriptor: first)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: first), 330)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: second), 610)
        coordinator.recordModuleContentHeight(410, descriptor: second)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: second), 410)
        coordinator.recordModuleContentHeight(100, descriptor: second)
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: second), 330)
        coordinator.setModuleExtended(true, descriptor: unsupported)
        XCTAssertFalse(coordinator.isModuleExtended(unsupported))
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: unsupported), 330)
        XCTAssertTrue(coordinator.isModuleExtended(second))
    }

    func testOpenMenuSuspendsHoverExitAndRestartsGraceAfterClosing() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        _ = preview.handle(.dwellElapsed)
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.menuOpened), [.cancelExit])
        XCTAssertEqual(preview.handle(.left), [])
        XCTAssertEqual(preview.handle(.exitElapsed), [])
        XCTAssertEqual(preview.phase, .preview)
        XCTAssertEqual(preview.handle(.menuClosed(pointerInside: false)), [.scheduleExit])
        XCTAssertEqual(preview.handle(.exitElapsed), [.dismissPreview])
    }

    func testClosingMenuInsideKeepsPreviewAndResetClearsSuspension() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        _ = preview.handle(.dwellElapsed)
        _ = preview.handle(.menuOpened)
        XCTAssertEqual(preview.handle(.menuClosed(pointerInside: true)), [])
        XCTAssertEqual(preview.phase, .preview)
        _ = preview.handle(.menuOpened)
        _ = preview.handle(.reset)
        XCTAssertFalse(preview.isMenuOpen)
        XCTAssertEqual(preview.phase, .idle)
    }

    func testSwipeFollowsMovedShortcutsPosition() {
        let slots: [IslandModuleID] = [.timer, .shelf, .quickSettings, .battery]
        XCTAssertEqual(IslandShortcutSwipe.target(current: .shelf, step: 1, pinned: slots,
                                                  enabled: { _ in true }), .quickSettings)
        XCTAssertEqual(IslandShortcutSwipe.target(current: .quickSettings, step: 1, pinned: slots,
                                                  enabled: { _ in true }), .battery)
        XCTAssertEqual(IslandShortcutSwipe.target(current: .quickSettings, step: -1, pinned: slots,
                                                  enabled: { _ in true }), .shelf)
        XCTAssertNil(IslandShortcutSwipe.target(current: .battery, step: 1, pinned: slots,
                                                enabled: { _ in true }))
    }

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
        settings.experimentalModulesEnabled = true
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

    func testNotchWingsFollowManualSelection() {
        let enabled: [IslandModuleID] = [.shelf, .timer, .battery]
        XCTAssertEqual(IslandNotchDisplay.selected(.battery, enabled: enabled), .battery)
        XCTAssertEqual(IslandNotchDisplay.selected(.timer, enabled: enabled), .timer)
        XCTAssertEqual(IslandNotchDisplay.selected(.shelf, enabled: enabled), .shelf)
    }

    func testCancelledDragRestoresPreviousModuleAndState() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer, pinned: true)
        XCTAssertFalse(coordinator.isDragInProgress)
        coordinator.beginDrag()
        XCTAssertTrue(coordinator.isDragInProgress)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
        coordinator.endDrag(imported: false)
        XCTAssertFalse(coordinator.isDragInProgress)
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

        XCTAssertEqual(coordinator.surfaceState, .collapsed)
        XCTAssertFalse(coordinator.canRevealOnHover)

        coordinator.setPointerHovering(false)
        XCTAssertTrue(coordinator.canRevealOnHover)
    }

    func testProgrammaticCollapseCanLeaveHoverRevealAvailable() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .shelf)

        coordinator.collapse(suppressHoverUntilPointerExit: false)

        XCTAssertEqual(coordinator.surfaceState, .collapsed)
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

    func testUnpinResumesDismissalAndAllowsReentryAndRepinning() {
        var preview = IslandHoverPreviewStateMachine()
        _ = preview.handle(.entered)
        _ = preview.handle(.dwellElapsed)
        _ = preview.handle(.committed)
        XCTAssertEqual(preview.handle(.unpinned(pointerInside: true)), [.cancelDwell, .cancelExit])
        XCTAssertEqual(preview.phase, .preview)
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.entered), [.cancelExit])
        XCTAssertEqual(preview.handle(.left), [.scheduleExit])
        XCTAssertEqual(preview.handle(.committed), [.cancelExit, .commitPreview])
        XCTAssertEqual(preview.handle(.exitElapsed), [])
        XCTAssertEqual(preview.handle(.unpinned(pointerInside: false)), [.cancelDwell, .cancelExit, .scheduleExit])
        XCTAssertEqual(preview.handle(.exitElapsed), [.dismissPreview])
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
        XCTAssertEqual(callbackStates.first?.0, .collapsed)
        XCTAssertEqual(callbackStates.first?.1, .expanded)
        XCTAssertEqual(callbackStates.first?.2, .collapsed)
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
        coordinator.selectedModule = .system
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
        XCTAssertEqual(coordinator.surfaceState, .collapsed)
        coordinator.completeSurfaceTransition(currentID)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)
    }
}
