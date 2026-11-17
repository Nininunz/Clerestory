import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class IslandPresentationControllerTests: XCTestCase {
    func testNotchToggleAndDisplayChangesPreserveExpandedWindowSelectionAndPinning() async throws {
        let name = "IslandPresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let coordinator = IslandActivityCoordinator(defaults: defaults)
        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)
        let modules = IslandModuleContainer(registrations: [], coordinator: coordinator)
        var screen = geometry(notched: true)
        var roles: [IslandWindowRole] = []
        let presentation = IslandPresentationController(
            settings: settings, coordinator: coordinator, registry: registry, modules: modules,
            notices: { nil }, collapse: { _ in coordinator.collapse() },
            makePanel: { role in
                roles.append(role)
                let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                return panel
            }, screenGeometry: { _ in screen })
        presentation.connect()
        defer { presentation.deactivate() }
        presentation.activate()
        coordinator.show(module: .quickSettings)
        XCTAssertFalse(presentation.expanded.panel.hasShadow)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        XCTAssertFalse(presentation.expanded.panel.hasShadow)
        coordinator.setPinned(true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let window = presentation.expanded.panel
        let frame = window.frame
        XCTAssertEqual(window.interactionFrame, coordinator.currentLayout?.expandedFrame)
        XCTAssertEqual(frame.width, window.interactionFrame.width + 2 * IslandSurfaceShadow.inset)
        settings.notchModuleID = .shelf
        XCTAssertTrue(presentation.notch.panel.isVisible)
        XCTAssertFalse(presentation.notch.panel.canBecomeKey)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.isVisible)
        for visible in [false, true, false] {
            settings.showNotch = visible
            presentation.activate()
            XCTAssertEqual(presentation.notch.panel.isVisible, visible)
            XCTAssertTrue(window === presentation.expanded.panel)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(coordinator.surfaceState, .pinned)
            XCTAssertEqual(coordinator.selectedModule, .quickSettings)
            XCTAssertEqual(settings.notchModuleID, .shelf)
        }
        settings.showNotch = true
        screen = geometry(notched: false)
        presentation.activate()
        XCTAssertFalse(presentation.notch.panel.isVisible)
        XCTAssertTrue(settings.showNotch)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(coordinator.selectedModule, .quickSettings)
        screen = geometry(notched: true)
        presentation.activate()
        XCTAssertTrue(presentation.notch.panel.isVisible)
        XCTAssertEqual(roles.filter { $0 == .expanded }.count, 1)
        XCTAssertEqual(roles.filter { $0 == .notch }.count, 1)

        coordinator.collapse()
        let closingTransition = coordinator.surfaceTransitionID
        XCTAssertFalse(window.hasShadow)
        presentation.scheduleIslandLayoutUpdate()
        XCTAssertFalse(window.hasShadow, "Defaults/layout updates must not restore a closing shadow")
        coordinator.show(module: .quickSettings)
        XCTAssertFalse(window.hasShadow)
        coordinator.completeSurfaceTransition(closingTransition)
        XCTAssertFalse(window.hasShadow, "Stale close completion must not restore the opening shadow")
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        XCTAssertFalse(window.hasShadow)
        coordinator.collapse()
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isVisible)

    }

    func testClickTriggerHonorsPreferenceWithOrWithoutNotchAndOnExternalDisplay() throws {
        for notched in [true, false] {
            for notch in [true, false] {
                let name = "IslandTriggers.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
                defer { defaults.removePersistentDomain(forName: name) }
                let settings = SettingsStore(defaults: defaults)
                settings.showNotch = notch
                let coordinator = IslandActivityCoordinator()
                let registry = IslandModuleRegistry()
                registry.apply(settings: settings)
                let screen = geometry(notched: notched)
                let presentation = IslandPresentationController(
                    settings: settings, coordinator: coordinator, registry: registry,
                    modules: IslandModuleContainer(registrations: [], coordinator: coordinator),
                    notices: { nil }, collapse: { _ in coordinator.collapse() },
                    makePanel: { _ in
                        ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
                    }, screenGeometry: { _ in screen })
                presentation.connect()
                defer { presentation.deactivate() }
                let trigger = presentation.islandLayout().pointerTriggerFrame
                let point = CGPoint(x: trigger.minX + 4, y: screen.frame.maxY)
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                settings.islandClickRevealEnabled = false
                presentation.handleIslandEvent(click, at: point)
                XCTAssertFalse(coordinator.surfaceState.isExpanded)
                settings.islandClickRevealEnabled = true
                presentation.handleIslandEvent(click, at: CGPoint(x: trigger.maxX + 1, y: point.y))
                XCTAssertFalse(coordinator.surfaceState.isExpanded)
                presentation.handleIslandEvent(click, at: point)
                XCTAssertTrue(coordinator.surfaceState.isExpanded)
                XCTAssertTrue(presentation.expanded.panel.isVisible)
            }
        }
    }

    func testPanelTriggerDisplayIsIndependentOfNotchAndPinnedPointerMovement() throws {
        let name = "IslandDisplays.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let coordinator = IslandActivityCoordinator(defaults: defaults)
        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)
        let builtIn = geometry(notched: true)
        let external = IslandGeometryResolver.ScreenGeometry(
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0, auxiliaryTopLeftArea: .zero, auxiliaryTopRightArea: .zero)
        var builtInConnected = true
        let presentation = IslandPresentationController(
            settings: settings, coordinator: coordinator, registry: registry,
            modules: IslandModuleContainer(registrations: [], coordinator: coordinator),
            notices: { nil }, collapse: { _ in coordinator.collapse() },
            makePanel: { _ in
                let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                return panel
            }, screenGeometry: { $0.x >= 1512 ? external : builtIn },
            notchScreenGeometry: { builtInConnected ? builtIn : nil })
        presentation.connect()
        presentation.activate()
        defer { presentation.deactivate() }
        let notchFrame = presentation.notch.panel.frame
        let externalPoint = CGPoint(x: external.frame.midX, y: external.frame.maxY)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        presentation.handleIslandEvent(click, at: externalPoint)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        XCTAssertEqual(coordinator.currentLayout?.screenFrame, external.frame)
        XCTAssertEqual(coordinator.notchLayout?.screenFrame, builtIn.frame)
        XCTAssertEqual(presentation.notch.panel.frame, notchFrame)
        coordinator.setPinned(true)
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        let builtInPoint = CGPoint(x: builtIn.frame.midX, y: builtIn.frame.maxY)
        XCTAssertEqual(presentation.islandLayout(at: builtInPoint).screenFrame, external.frame)
        builtInConnected = false
        presentation.scheduleIslandLayoutUpdate()
        XCTAssertFalse(presentation.notch.panel.isVisible)
        XCTAssertEqual(coordinator.currentLayout?.screenFrame, external.frame)
        builtInConnected = true
        presentation.scheduleIslandLayoutUpdate()
        XCTAssertTrue(presentation.notch.panel.isVisible)
        coordinator.collapse()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduced motion dismisses immediately, releasing the display for the next trigger.
            XCTAssertFalse(presentation.expanded.panel.isVisible)
            XCTAssertEqual(presentation.islandLayout(at: builtInPoint).screenFrame, builtIn.frame)
        } else {
            // Animated dismissal keeps the original display until completion.
            XCTAssertEqual(presentation.islandLayout(at: builtInPoint).screenFrame, external.frame)
        }
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        presentation.handleIslandEvent(click, at: builtInPoint)
        XCTAssertEqual(coordinator.currentLayout?.screenFrame, builtIn.frame)
        XCTAssertEqual(presentation.notch.panel.frame, notchFrame)
    }

    private func geometry(notched: Bool) -> IslandGeometryResolver.ScreenGeometry {
        .init(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
              visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
              safeAreaTop: notched ? 38 : 0,
              auxiliaryTopLeftArea: notched ? CGRect(x: 0, y: 0, width: 645, height: 38) : .zero,
              auxiliaryTopRightArea: notched ? CGRect(x: 0, y: 0, width: 645, height: 38) : .zero)
    }
}
