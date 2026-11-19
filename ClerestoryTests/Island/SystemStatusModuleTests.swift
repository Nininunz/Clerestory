import XCTest
@testable import Clerestory

final class SystemStatusMetricTests: XCTestCase {
    func testCPUUsageUsesTickDifferences() {
        let usage = SystemMetricMath.cpuUsage(
            previous: .init(user: 100, system: 50, idle: 350, nice: 0),
            current: .init(user: 140, system: 70, idle: 420, nice: 10)
        )
        XCTAssertEqual(usage ?? -1, 0.5, accuracy: 0.0001)
    }

    func testCounterRolloverIsHandled() {
        XCTAssertEqual(
            SystemMetricMath.wrappingDelta(previous: UInt64.max - 4, current: 3),
            8
        )
        let rates = SystemMetricMath.networkRates(
            previous: .init(received: UInt64.max - 9, sent: 100),
            current: .init(received: 10, sent: 300),
            elapsed: 2
        )
        XCTAssertEqual(rates?.download, 10)
        XCTAssertEqual(rates?.upload, 100)
    }

    func testCPUTickRolloverUsesMachThirtyTwoBitCounterWidth() {
        let maximum = UInt64(UInt32.max)
        let usage = SystemMetricMath.cpuUsage(
            previous: .init(user: maximum - 4, system: 10, idle: maximum - 9, nice: 0),
            current: .init(user: 5, system: 20, idle: 10, nice: 0)
        )
        XCTAssertEqual(usage ?? -1, 20.0 / 40.0, accuracy: 0.0001)
    }

    func testMemoryUsedExcludesPurgeableActivePages() {
        XCTAssertEqual(SystemMetricMath.memoryUsedPages(
            active: 100,
            wired: 30,
            compressor: 20,
            purgeable: 10
        ), 140)
        XCTAssertEqual(SystemMetricMath.memoryUsedPages(
            active: 5,
            wired: 3,
            compressor: 2,
            purgeable: 20
        ), 5)
    }

    func testAdaptiveRefreshIntervals() {
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: false,
            thermalStatus: .nominal
        ), .seconds(1))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: false,
            isLowPowerModeEnabled: false,
            thermalStatus: .nominal
        ), .seconds(5))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: true,
            thermalStatus: .nominal
        ), .seconds(15))
        XCTAssertEqual(SystemRefreshPolicy.interval(
            isSelectedAndExpanded: true,
            isLowPowerModeEnabled: false,
            thermalStatus: .critical
        ), .seconds(15))
    }

    @MainActor
    func testMemoryPressureEventOverridesUnavailableSample() async {
        let provider = FixedSystemProvider(snapshot: .unavailable())
        let store = SystemStatusModuleStore(
            provider: provider,
            isSelectedAndExpanded: { false }
        )
        store.start()
        await store.refresh()
        store.processMemoryPressureEvent(.critical)
        XCTAssertEqual(store.snapshot.memoryPressure, .critical)
        XCTAssertEqual(store.alerts.first?.key, "memory-pressure")
        store.stop()
    }

    @MainActor
    func testEachSampleSetsTheWholeSetOfStatuses() async {
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(announcer: .recording(into: spoken))
        let (store, provider) = startedStore(messages: messages)

        var warning = SystemSnapshot.unavailable()
        warning.thermalStatus = .serious
        warning.diskAvailableBytes = 5_000_000_000
        warning.diskTotalBytes = 500_000_000_000
        await provider.set(warning)
        await store.refresh()
        XCTAssertEqual(Set(messages.statuses(for: .system).map(\.key)), ["thermal", "disk-space"])
        XCTAssertTrue(messages.statuses(for: .system).allSatisfy { $0.tone == .warning && $0.expiresAt == nil })
        XCTAssertEqual(store.alerts.map(\.key), ["thermal", "disk-space"], "The page keeps the sample order")
        XCTAssertEqual(spoken.messages.count, 2, "Thermal and disk warnings are announced once when raised")

        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 2, "An unchanged sample is silent")

        warning.thermalStatus = .nominal
        await provider.set(warning)
        await store.refresh()
        XCTAssertEqual(messages.statuses(for: .system).map(\.key), ["disk-space"])

        await provider.set(.unavailable())
        await store.refresh()
        XCTAssertTrue(messages.statuses(for: .system).isEmpty)
        XCTAssertTrue(store.alerts.isEmpty)
        store.stop()
    }

    @MainActor
    func testIgnoreDismissesOnlyThatKeyUntilItClearsAndReturns() async {
        let messages = IslandMessageCenter.forTesting()
        let (store, provider) = startedStore(messages: messages)

        var warning = SystemSnapshot.unavailable()
        warning.thermalStatus = .serious
        warning.diskAvailableBytes = 5_000_000_000
        warning.diskTotalBytes = 500_000_000_000
        await provider.set(warning)
        await store.refresh()
        store.ignoreAlert("thermal")
        XCTAssertEqual(messages.statuses(for: .system).map(\.key), ["disk-space"])
        XCTAssertEqual(store.alerts.map(\.key), ["disk-space"])

        await store.refresh()
        XCTAssertEqual(store.alerts.map(\.key), ["disk-space"], "Ignored while the condition holds")

        var cleared = warning
        cleared.thermalStatus = .nominal
        await provider.set(cleared)
        await store.refresh()
        await provider.set(warning)
        await store.refresh()
        XCTAssertEqual(store.alerts.map(\.key), ["thermal", "disk-space"], "It returns once raised again")
        store.stop()
    }

    @MainActor
    func testApplicationAlertsLastUntilTheNextSampleAndAreNeverAnnounced() async {
        let clock = ManualMessageClock()
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(clock: clock, announcer: .recording(into: spoken))
        messages.setNoticeClockRunning(true)
        var now = Date(timeIntervalSince1970: 10_000)
        let (store, provider) = startedStore(messages: messages, now: { now })

        await provider.set(snapshotWithApplication(cpu: 0, memory: 3_000_000_000))
        await store.refresh()
        let key = "application.com.example.app"
        let status = messages.topStatus(for: .system)
        XCTAssertEqual(status?.key, key)
        XCTAssertEqual(status?.tone, .warning)
        XCTAssertNil(status?.expiresAt)
        XCTAssertEqual(status?.isDismissible, true)
        XCTAssertTrue(spoken.messages.isEmpty, "Application alerts are never announced")
        XCTAssertNil(messages.currentNotice)

        // The old 12 s expiry left a gap before the next 15 s sample.
        await clock.advance(by: 14.9)
        XCTAssertEqual(messages.statuses(for: .system).map(\.key), [key])
        XCTAssertEqual(store.alerts.map(\.key), [key])

        now = now.addingTimeInterval(15)
        await store.refresh()
        XCTAssertTrue(messages.statuses(for: .system).isEmpty, "The evaluator reports it once per cooldown")
        XCTAssertTrue(store.alerts.isEmpty, "The page and the Notch drop it together")
        store.stop()
    }

    @MainActor
    func testGettingWorseAnnouncesOnceAndImprovingIsSilent() async {
        let spoken = AnnouncementRecorder()
        let messages = IslandMessageCenter.forTesting(announcer: .recording(into: spoken))
        let (store, provider) = startedStore(messages: messages)

        var sample = SystemSnapshot.unavailable()
        sample.memoryPressure = .warning
        sample.thermalStatus = .serious
        await provider.set(sample)
        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 2)

        sample.memoryPressure = .critical
        sample.thermalStatus = .critical
        await provider.set(sample)
        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 4, "Critical is a higher level, so each announces once")
        XCTAssertTrue(spoken.messages.contains("Memory pressure is critical, Apps may slow down"))
        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 4)

        sample.memoryPressure = .warning
        sample.thermalStatus = .serious
        await provider.set(sample)
        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 4, "Improving is silent")
        XCTAssertEqual(messages.topStatus(for: .system)?.level, 0)

        sample.memoryPressure = .critical
        await provider.set(sample)
        await store.refresh()
        XCTAssertEqual(spoken.messages.count, 5, "Flapping back up announces once more")
        store.stop()
    }

    /// A store marked running without its sampling loop, so the test's own `refresh()` calls are
    /// its only samples.
    @MainActor
    private func startedStore(
        messages: IslandMessageCenter,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> (SystemStatusModuleStore, ScriptedSystemProvider) {
        let provider = ScriptedSystemProvider(snapshot: .unavailable())
        let store = SystemStatusModuleStore(provider: provider, isSelectedAndExpanded: { false },
                                            now: now, messenger: messages.messenger(for: .system))
        messages.moduleDidStart(.system)
        store.startForTesting()
        return (store, provider)
    }

    func testApplicationCPURequiresSixtySecondsAndThenCoolsDown() {
        var evaluator = SystemApplicationAlertEvaluator()
        let start = Date(timeIntervalSince1970: 1_000)
        var snapshot = snapshotWithApplication(cpu: 0.9, memory: 100)
        XCTAssertTrue(evaluator.alerts(for: snapshot, at: start).isEmpty)
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: start.addingTimeInterval(60)).count, 1)
        XCTAssertTrue(evaluator.alerts(for: snapshot,
                                       at: start.addingTimeInterval(120)).isEmpty)

        snapshot = snapshotWithApplication(cpu: 0.1, memory: 3_000_000_000)
        XCTAssertTrue(evaluator.alerts(for: snapshot,
                                       at: start.addingTimeInterval(959)).isEmpty)
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: start.addingTimeInterval(961)).count, 1)
    }

    func testApplicationMemoryThresholdIsMaxOfTwoGBAndFifteenPercent() {
        var evaluator = SystemApplicationAlertEvaluator()
        let date = Date(timeIntervalSince1970: 2_000)
        var snapshot = snapshotWithApplication(cpu: 0, memory: 2_100_000_000)
        snapshot.memoryTotalBytes = 64_000_000_000
        XCTAssertTrue(evaluator.alerts(for: snapshot, at: date).isEmpty)

        snapshot = snapshotWithApplication(cpu: 0, memory: 10_000_000_000)
        snapshot.memoryTotalBytes = 64_000_000_000
        XCTAssertEqual(evaluator.alerts(for: snapshot,
                                        at: date.addingTimeInterval(1)).count, 1)
    }

    private func snapshotWithApplication(cpu: Double, memory: UInt64) -> SystemSnapshot {
        var snapshot = SystemSnapshot.unavailable(at: Date(timeIntervalSince1970: 0))
        snapshot.memoryTotalBytes = 8_000_000_000
        snapshot.topApplications = [
            .init(id: "com.example.app", processIdentifier: 42, name: "Example",
                  bundleIdentifier: "com.example.app", cpuUsage: cpu,
                  memoryBytes: memory),
        ]
        return snapshot
    }
}

private actor FixedSystemProvider: SystemStatusProviding {
    let fixedSnapshot: SystemSnapshot

    init(snapshot: SystemSnapshot) {
        fixedSnapshot = snapshot
    }

    func sample() async -> SystemSnapshot { fixedSnapshot }
}

private actor ScriptedSystemProvider: SystemStatusProviding {
    private var snapshot: SystemSnapshot

    init(snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    func set(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    func sample() async -> SystemSnapshot { snapshot }
}
