import SwiftUI
import XCTest
@testable import Clerestory

@MainActor
final class IslandModuleContainerTests: XCTestCase {
    func testExperimentalGateStopsRuntimeAndCanRestartSavedModule() throws {
        let name = "ExperimentalRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setIslandModuleEnabled(true, id: .timer)
        let runtime = RuntimeSpy(id: .timer)
        let container = makeContainer(runtime: runtime)
        container.apply(configuration: settings.effectiveIslandModuleConfiguration, isActive: true)
        XCTAssertEqual(runtime.startCount, 0)
        settings.experimentalModulesEnabled = true
        container.apply(configuration: settings.effectiveIslandModuleConfiguration, isActive: true)
        XCTAssertEqual(runtime.startCount, 1)
        settings.experimentalModulesEnabled = false
        container.apply(configuration: settings.effectiveIslandModuleConfiguration, isActive: true)
        XCTAssertEqual(runtime.stopCount, 1)
        XCTAssertTrue(container.runningModuleIDs.isEmpty)
        settings.experimentalModulesEnabled = true
        container.apply(configuration: settings.effectiveIslandModuleConfiguration, isActive: true)
        XCTAssertEqual(runtime.startCount, 2)
        container.stopAll()
    }

    func testQuickSettingsRemainsAvailableWithoutPinnedOrEnabledModules() {
        let runtime = RuntimeSpy(id: .quickSettings)
        let coordinator = IslandActivityCoordinator()
        let container = makeContainer(runtime: runtime)
        let configuration = IslandModuleConfiguration(enabledModuleIDs: [], pinnedModuleIDs: [])

        coordinator.show(module: .quickSettings)
        container.apply(configuration: configuration, isActive: true)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(coordinator.selectedModule, .quickSettings)
        XCTAssertTrue(IslandModuleRegistry().isEnabled(.quickSettings))
        XCTAssertNotNil(IslandModuleRegistry().descriptor(for: .quickSettings))

        coordinator.show(module: .shelf)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        container.apply(configuration: configuration, isActive: false)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testLifecycleIsIdempotentAndDisabledRuntimeStops() {
        let runtime = RuntimeSpy(id: .timer)
        let container = makeContainer(runtime: runtime)
        let enabled = IslandModuleConfiguration(
            enabledModuleIDs: [.timer], pinnedModuleIDs: [.timer]
        )

        container.apply(configuration: enabled, isActive: true)
        container.apply(configuration: enabled, isActive: true)
        XCTAssertEqual(runtime.startCount, 1)

        container.apply(configuration: .init(enabledModuleIDs: [], pinnedModuleIDs: []),
                        isActive: true)
        container.apply(configuration: .init(enabledModuleIDs: [], pinnedModuleIDs: []),
                        isActive: true)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testStatusesAreDroppedOnStopAndIgnoredUntilTheNextStart() {
        let runtime = RuntimeSpy(id: .timer)
        let messages = IslandMessageCenter.forTesting()
        runtime.messenger = messages.messenger(for: .timer)
        let container = makeContainer(runtime: runtime, messages: messages)
        let enabled = IslandModuleConfiguration(enabledModuleIDs: [.timer], pinnedModuleIDs: [])
        container.apply(configuration: enabled, isActive: true)
        runtime.setStatus("first")
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["first"])

        container.stopAll()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        runtime.setStatus("late")
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty, "A stopped module cannot set statuses")
    }

    /// Modules write through a messenger rather than a one-shot event stream, so a module that
    /// stops and starts again keeps updating its statuses.
    func testModuleKeepsUpdatingAfterStopAndStart() throws {
        let name = "ContainerRestart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let messages = IslandMessageCenter.forTesting()
        let timer = IslandTimerStore(defaults: defaults)
        timer.messenger = messages.messenger(for: .timer)
        let runtime = CallbackIslandModuleRuntime(descriptor: timer.descriptor,
                                                  start: { timer.start() }, stop: { timer.stop() })
        let container = IslandModuleContainer(registrations: [.init(
            descriptor: runtime.descriptor, runtime: runtime, makeContentView: { _ in AnyView(EmptyView()) }
        )], messages: messages)
        let enabled = IslandModuleConfiguration(enabledModuleIDs: [.timer], pinnedModuleIDs: [])
        let disabled = IslandModuleConfiguration(enabledModuleIDs: [], pinnedModuleIDs: [])

        container.apply(configuration: enabled, isActive: true)
        timer.start(duration: 60)
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["running"])
        timer.reset()
        container.apply(configuration: disabled, isActive: true)
        container.apply(configuration: enabled, isActive: true)
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)

        timer.start(duration: 60)
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["running"])
        timer.pause()
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["running"])
        timer.reset()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        container.stopAll()
    }

    func testModuleIsStartedInTheCenterBeforeItsRuntimeStarts() {
        let messages = IslandMessageCenter.forTesting()
        let runtime = RuntimeSpy(id: .timer)
        runtime.onStart = {
            // A module that sets a status while starting, as Transfers and Battery do.
            messages.messenger(for: .timer).setStatus(.init(key: "running", title: "Focus",
                                                            systemImage: "timer"))
        }
        var statusesAtStop: [IslandStatus] = []
        runtime.onStop = { statusesAtStop = messages.statuses(for: .timer) }
        let container = makeContainer(runtime: runtime, messages: messages)
        container.apply(configuration: .init(enabledModuleIDs: [.timer], pinnedModuleIDs: []), isActive: true)
        XCTAssertTrue(messages.isModuleStarted(.timer))
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["running"])

        container.stopAll()
        XCTAssertEqual(statusesAtStop.map(\.key), ["running"], "The center clears statuses after stop()")
        XCTAssertFalse(messages.isModuleStarted(.timer))
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
    }

    func testShelfCountsAsStartedWhileItIsEnabled() {
        let messages = IslandMessageCenter.forTesting()
        let runtime = RuntimeSpy(id: .shelf)
        let container = makeContainer(runtime: runtime, messages: messages)
        XCTAssertFalse(messages.isModuleStarted(.shelf))
        container.apply(configuration: .init(enabledModuleIDs: [.shelf], pinnedModuleIDs: []), isActive: true)
        XCTAssertTrue(messages.isModuleStarted(.shelf))
        // Notices are never gated: Shelf startup notices are posted before any module starts.
        container.apply(configuration: .init(enabledModuleIDs: [], pinnedModuleIDs: []), isActive: true)
        XCTAssertFalse(messages.isModuleStarted(.shelf))
        messages.messenger(for: .shelf).post(.alreadyOnShelf)
        XCTAssertEqual(messages.currentNotice?.moduleID, .shelf)
    }

    private func makeContainer(
        runtime: RuntimeSpy,
        messages: IslandMessageCenter = .forTesting()
    ) -> IslandModuleContainer {
        IslandModuleContainer(
            registrations: [.init(
                descriptor: runtime.descriptor,
                runtime: runtime,
                makeContentView: { _ in AnyView(EmptyView()) }
            )],
            messages: messages
        )
    }
}

@MainActor
private final class RuntimeSpy: IslandModuleRuntime {
    let descriptor: IslandModuleDescriptor
    var messenger: ModuleMessenger = .inert
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: IslandModuleID) {
        descriptor = .init(id: id, title: id.rawValue,
                           systemImage: "circle", order: 0, isCore: false)
    }

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    func start() { startCount += 1; onStart() }
    func stop() { stopCount += 1; onStop() }
    /// Replaces the module's statuses with one, as a store does on each update.
    func setStatus(_ key: String) {
        messenger.setStatuses([.init(key: key, title: key, systemImage: "circle")])
    }
}
