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

    func testEventsBecomeStatusesAndAreDroppedOnStop() async {
        let runtime = RuntimeSpy(id: .timer)
        let messages = IslandMessageCenter.forTesting()
        let container = makeContainer(runtime: runtime, messages: messages)
        let enabled = IslandModuleConfiguration(
            enabledModuleIDs: [.timer], pinnedModuleIDs: []
        )
        container.apply(configuration: enabled, isActive: true)
        runtime.publish(.publishActivity(activity(id: "first")))
        await settleEvents()
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["first"])

        container.stopAll()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        runtime.publish(.publishActivity(activity(id: "late")))
        await settleEvents()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
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

    /// Replaces testRuntimeCannotPublishActivityForAnotherModule: the adapter writes through the
    /// sending module's messenger, so a module can neither add nor remove another's statuses.
    func testAdapterKeepsEachModulesStatusesToItself() async {
        let timer = RuntimeSpy(id: .timer)
        let battery = RuntimeSpy(id: .battery)
        let messages = IslandMessageCenter.forTesting()
        let container = IslandModuleContainer(registrations: [timer, battery].map { runtime in
            .init(descriptor: runtime.descriptor, runtime: runtime, makeContentView: { _ in AnyView(EmptyView()) })
        }, messages: messages)
        container.apply(configuration: .init(enabledModuleIDs: [.timer, .battery], pinnedModuleIDs: []),
                        isActive: true)
        battery.publish(.publishActivity(.init(
            id: "battery.low", moduleID: .battery, priority: .criticalBattery,
            title: "Battery low", detail: "15%", systemImage: "battery.25percent", expiresAt: nil
        )))
        timer.publish(.publishActivity(.init(
            id: "forged", moduleID: .battery, priority: .systemWarning,
            title: "Forged", detail: nil, systemImage: "xmark", expiresAt: nil
        )))
        timer.publish(.removeActivity(id: "battery.low"))
        timer.publish(.removeAllActivities)
        await settleEvents()

        XCTAssertEqual(messages.statuses(for: .battery).map(\.key), ["battery.low"])
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        container.stopAll()
    }

    func testAdapterMapsPrioritiesToTheTintsTheyHadAndNeverAnnounces() async {
        let expected: [(IslandActivityPriority, IslandStatus.Tone)] = [
            (.criticalBattery, .critical), (.systemWarning, .warning), (.timerFinished, .warning),
            (.transfer, .progress), (.userDrag, .progress), (.shelfSummary, .neutral),
            (.selectedModule, .neutral), (.nowPlaying, .neutral), (.powerChange, .neutral),
        ]
        for (priority, tone) in expected {
            XCTAssertEqual(IslandActivityStatusAdapter.tone(for: priority), tone, "\(priority)")
        }

        let clock = ManualMessageClock()
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(clock: clock, announcer: .recording(into: spoken))
        messages.setNoticeClockRunning(true)
        messages.moduleDidStart(.aiUsage)
        let aiUsage = messages.messenger(for: .aiUsage)
        IslandActivityStatusAdapter.apply(.publishActivity(.init(
            id: "aiUsage.limit.5h.80", moduleID: .aiUsage, priority: .systemWarning,
            title: "5h limit at 80%", detail: "Resets in 2 h", systemImage: "gauge.with.dots.needle.100percent",
            expiresAt: Date().addingTimeInterval(600)
        )), to: aiUsage)
        let status = messages.topStatus(for: .aiUsage)
        XCTAssertEqual(status?.title, "5h limit at 80%")
        XCTAssertEqual(status?.detail, "Resets in 2 h")
        XCTAssertEqual(status?.tone, .warning)
        XCTAssertFalse(status?.announcesWhenRaised ?? true)
        XCTAssertTrue(spoken.messages.isEmpty, "Unmigrated modules do not speak")
        XCTAssertNil(messages.currentNotice, "Unmigrated modules do not show a pill")

        await clock.advance(by: 599)
        XCTAssertNotNil(messages.topStatus(for: .aiUsage))
        await clock.advance(by: 2)
        XCTAssertNil(messages.topStatus(for: .aiUsage), "The activity's expiry carries over")
    }

    func testReplacingAnActivityUpdatesItsStatusWithoutClearingIt() async {
        let runtime = CallbackIslandModuleRuntime(descriptor: .init(id: .timer, title: "Timer", systemImage: "timer",
                                                                    order: 0, isCore: false))
        let messages = IslandMessageCenter.forTesting()
        let container = IslandModuleContainer(registrations: [.init(
            descriptor: runtime.descriptor, runtime: runtime, makeContentView: { _ in AnyView(EmptyView()) }
        )], messages: messages)
        container.apply(configuration: .init(enabledModuleIDs: [.timer], pinnedModuleIDs: []), isActive: true)
        runtime.replaceActivity(activity(id: "timer.running"))
        await settleEvents()
        let probe = ObservationProbe()
        probe.track { _ = messages.statuses(for: .timer) }
        runtime.replaceActivity(activity(id: "timer.running"))
        await settleEvents()
        XCTAssertEqual(probe.changes, 0, "An unchanged activity is not removed and published again")

        runtime.replaceActivity(activity(id: "timer.finished"))
        await settleEvents()
        XCTAssertEqual(messages.statuses(for: .timer).map(\.key), ["timer.finished"])
        runtime.replaceActivity(nil)
        await settleEvents()
        XCTAssertTrue(messages.statuses(for: .timer).isEmpty)
        container.stopAll()
    }

    /// Lets the container's event tasks drain what the runtimes yielded.
    private func settleEvents() async {
        for _ in 0..<20 { await Task.yield() }
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

    private func activity(id: String) -> IslandActivity {
        .init(id: id, moduleID: .timer, priority: .timerFinished,
              title: id, detail: nil, systemImage: "timer", expiresAt: nil)
    }
}

@MainActor
private final class RuntimeSpy: IslandModuleRuntime {
    let descriptor: IslandModuleDescriptor
    let events: AsyncStream<IslandModuleEvent>
    private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: IslandModuleID) {
        descriptor = .init(id: id, title: id.rawValue,
                           systemImage: "circle", order: 0, isCore: false)
        var captured: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    func start() { startCount += 1; onStart() }
    func stop() { stopCount += 1; onStop() }
    func publish(_ event: IslandModuleEvent) { continuation.yield(event) }
}
