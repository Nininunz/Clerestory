import IOKit.ps
import XCTest
@testable import Clerestory

@MainActor
final class PowerSourceMonitorTests: XCTestCase {
    func testStartingWhileLockedResumesSamplingOnUnlockAndStaysStoppedAfterStop() async {
        var allowed = false
        var reads = 0
        let monitor = PowerSourceMonitor(samplingAllowed: { allowed }, snapshotProvider: {
            reads += 1
            return .init(hasBattery: true, percentage: 80, isCharging: false, isConnectedToPower: false)
        })
        monitor.start()
        monitor.start()
        XCTAssertEqual(reads, 0)
        allowed = true
        NotificationCenter.default.post(name: .clerestoryResourcePolicyDidChange, object: nil)
        for _ in 0..<20 where reads == 0 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(monitor.snapshot.hasBattery)
        monitor.stop()
        monitor.refresh()
        NotificationCenter.default.post(name: .clerestoryResourcePolicyDidChange, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(monitor.isRunning)
    }

    func testSnapshotParsesCapacityAndPowerState() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 45,
            kIOPSMaxCapacityKey: 90,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
            kIOPSVoltageKey: 12_000,
            kIOPSCurrentKey: 2_000,
        ])
        XCTAssertEqual(snapshot.percentage, 50)
        XCTAssertTrue(snapshot.hasBattery)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isConnectedToPower)
        XCTAssertEqual(snapshot.powerWatts, 24)
    }

    func testBatteryPowerUsesRegistryFallbackAndDischargeDirection() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 75,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false,
            kIOPSVoltageKey: 0,
            kIOPSCurrentKey: 0,
        ], registryProperties: [
            "Voltage": 12_500,
            "InstantAmperage": 800,
        ])

        XCTAssertEqual(snapshot.powerWatts, -10)
    }

    func testNestedBatteryDetailsAndUnknownChargingEstimate() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 50,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
            kIOPSTimeToFullChargeKey: -1,
        ], registryProperties: [
            "CycleCount": 96,
            "BatteryData": ["DesignCapacity": 8579, "FullChargeCapacity": 8472],
        ], packProperties: ["BatteryData": ["Temperature": 3009]],
           adapterProperties: [kIOPSPowerAdapterWattsKey: 94])

        XCTAssertNil(snapshot.estimatedMinutes)
        XCTAssertTrue(snapshot.isCalculatingEstimate)
        XCTAssertEqual(snapshot.cycleCount, 96)
        XCTAssertEqual(snapshot.designCapacity, 8579)
        XCTAssertEqual(snapshot.fullChargeCapacity, 8472)
        XCTAssertEqual(snapshot.temperatureCelsius, 30.09)
        XCTAssertEqual(snapshot.adapterWatts, 94)
    }

    func testLegacyDetailsIgnoreTimeSentinelAndDisconnectedAdapter() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 50,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSTimeToEmptyKey: 65_535,
        ], registryProperties: [
            "DesignCapacity": 8000,
            "AppleRawMaxCapacity": 7200,
            "Temperature": 2850,
            "AdapterDetails": ["Name": "USB-C Adapter", "Watts": 60],
        ])

        XCTAssertNil(snapshot.estimatedMinutes)
        XCTAssertFalse(snapshot.isCalculatingEstimate)
        XCTAssertNil(snapshot.adapterWatts)
        XCTAssertNil(snapshot.adapterName)
        XCTAssertEqual(snapshot.fullChargeCapacity, 7200)
        XCTAssertEqual(snapshot.temperatureCelsius, 28.5)
    }

    func testMissingMaximumIsUnavailable() {
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: [:]), .unavailable)
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: nil), .unavailable)
    }

    // MARK: - Statuses and notices

    func testLowPowerModeNoticeOnlyFollowsObservedStateChanges() {
        let (monitor, center) = makeMonitor()
        var reading = snapshot(percentage: 80)
        reading.lowPowerMode = true
        monitor.process(reading)
        monitor.process(reading)
        XCTAssertTrue(spoken.messages.isEmpty)

        reading.lowPowerMode = false
        monitor.process(reading)
        monitor.process(reading)
        reading.lowPowerMode = true
        monitor.process(reading)
        XCTAssertEqual(spoken.messages, ["Low Power Mode disabled", "Low Power Mode enabled"])
        XCTAssertEqual(center.currentNotice?.notice.key, "low-power-mode")
    }

    func testLowThenPlugInKeepsLowAndPostsPowerNotice() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 15))
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        let noticesBefore = noticeKeys(center)

        monitor.process(snapshot(percentage: 15, power: true))
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        XCTAssertEqual(noticeKeys(center), noticesBefore + ["power"])
        XCTAssertEqual(spoken.messages, ["Battery low, 15%", "Power connected, 15%"],
                       "Plugging in does not raise low again")
    }

    func testUnplugIntoTheBandSetsLowAndPostsPowerNotice() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 21, power: true))
        monitor.process(snapshot(percentage: 20, power: false))
        XCTAssertEqual(center.statuses(for: .battery), [low(20)])
        XCTAssertEqual(noticeKeys(center), ["status.low", "power"],
                       "The raised status and the power change both show, one after the other")
        XCTAssertEqual(center.currentNotice?.notice.title, "Battery low · 20%")
        XCTAssertEqual(center.waitingNotices.first?.notice.title, "Running on battery · 20%")
    }

    func testStopThenStartInTheSameBandSetsLowAgain() {
        let center = makeCenter()
        let monitor = PowerSourceMonitor(samplingAllowed: { true }, snapshotProvider: {
            .init(hasBattery: true, percentage: 15, isCharging: false, isConnectedToPower: false)
        })
        monitor.messenger = center.messenger(for: .battery)
        monitor.start()
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        monitor.stop()
        center.moduleDidStop(.battery)
        XCTAssertTrue(center.statuses(for: .battery).isEmpty)

        center.moduleDidStart(.battery)
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        XCTAssertEqual(spoken.messages.filter { $0 == "Battery low, 15%" }.count, 2,
                       "Each start raises low again")
    }

    func testLowIsRaisedOncePerBand() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 21))
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 18))
        XCTAssertEqual(center.statuses(for: .battery), [low(18)])
        XCTAssertEqual(spoken.messages, ["Battery low, 20%"], "A lower percentage in the band is silent")
        monitor.process(snapshot(percentage: 10))
        XCTAssertEqual(center.topStatus(for: .battery)?.title, "Battery critically low")
        XCTAssertEqual(center.topStatus(for: .battery)?.tone, .critical)
        XCTAssertEqual(spoken.messages, ["Battery low, 20%", "Battery critically low, 10%"])
    }

    func testChargingOutOfCriticallyLowDoesNotAnnounceAgain() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 10, power: true))
        XCTAssertEqual(spoken.messages, ["Battery critically low, 10%"])
        let noticesBefore = noticeKeys(center)

        monitor.process(snapshot(percentage: 11, power: true))
        XCTAssertEqual(center.topStatus(for: .battery)?.title, "Battery low", "The title follows the charge")
        XCTAssertEqual(spoken.messages, ["Battery critically low, 10%"], "A rising charge is silent")
        XCTAssertEqual(noticeKeys(center), noticesBefore, "and shows no new pill")

        monitor.process(snapshot(percentage: 11, power: false))
        monitor.process(snapshot(percentage: 10, power: false))
        XCTAssertEqual(spoken.messages.last, "Battery critically low, 10%", "Falling again announces")
    }

    func testPowerChangeNoticeLastsTwoPointFiveSeconds() async {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 80, power: false))
        monitor.process(snapshot(percentage: 80, power: true))
        XCTAssertEqual(center.currentNotice?.notice.key, "power")
        XCTAssertEqual(center.currentNotice?.notice.title, "Power connected · 80%")
        XCTAssertEqual(center.currentNotice?.notice.systemImage, "bolt.fill")
        await clock.advance(by: 2.4)
        XCTAssertNotNil(center.currentNotice)
        await clock.advance(by: 0.1)
        XCTAssertNil(center.currentNotice)
    }

    func testRecoveringAboveTheLowThresholdClearsLow() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 20))
        XCTAssertEqual(center.currentNotice?.raisedStatusKey, "low")
        monitor.process(snapshot(percentage: 21))
        XCTAssertTrue(center.statuses(for: .battery).isEmpty)
        XCTAssertNil(center.currentNotice, "The raised notice goes with its status")
    }

    /// Unplugging while the mode also changes posts one notice, not two.
    func testUnplugWithModeChangePostsOnlyThePowerNotice() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 80, power: true))
        var reading = snapshot(percentage: 80, power: false)
        reading.lowPowerMode = true
        monitor.process(reading)
        XCTAssertEqual(noticeKeys(center), ["power"])
    }

    func testLowSurvivesPowerAndLowPowerModeNotices() async {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 15))
        await clock.advance(by: IslandMessageCenter.defaultDuration)
        XCTAssertNil(center.currentNotice)

        monitor.process(snapshot(percentage: 15, power: true))
        XCTAssertEqual(center.currentNotice?.notice.key, "power")
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        await clock.advance(by: PowerSourceMonitor.powerNoticeDuration)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(center.statuses(for: .battery), [low(15)], "No notice removes the status")

        var reading = snapshot(percentage: 15, power: true)
        reading.lowPowerMode = true
        monitor.process(reading)
        XCTAssertEqual(center.currentNotice?.notice.key, "low-power-mode")
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        await clock.advance(by: PowerSourceMonitor.powerNoticeDuration)
        XCTAssertNil(center.currentNotice)
        XCTAssertEqual(center.statuses(for: .battery), [low(15)])
        XCTAssertEqual(spoken.messages.filter { $0.hasPrefix("Battery low") }.count, 1,
                       "Low was raised once and never republished")
    }

    func testLosingTheBatteryClearsLow() {
        let (monitor, center) = makeMonitor()
        monitor.process(snapshot(percentage: 15))
        monitor.process(.unavailable)
        XCTAssertTrue(center.statuses(for: .battery).isEmpty)
    }

    private let clock = ManualMessageClock()
    private var spoken: AnnouncementRecorder!

    override func setUp() async throws {
        spoken = AnnouncementRecorder()
    }

    private func makeCenter() -> IslandMessageCenter {
        let center = IslandMessageCenter.forTesting(clock: clock, announcer: .recording(into: spoken))
        center.setNoticeClockRunning(true)
        center.moduleDidStart(.battery)
        return center
    }

    /// The messenger holds the center weakly, so a test keeps the returned center alive.
    private func makeMonitor() -> (PowerSourceMonitor, IslandMessageCenter) {
        let center = makeCenter()
        let monitor = PowerSourceMonitor()
        monitor.messenger = center.messenger(for: .battery)
        return (monitor, center)
    }

    private func noticeKeys(_ center: IslandMessageCenter) -> [String] {
        ([center.currentNotice] + center.waitingNotices).compactMap { $0?.notice.key }
    }

    private func low(_ percentage: Int) -> IslandStatus {
        IslandStatus(key: "low", title: percentage <= 10 ? "Battery critically low" : "Battery low",
                     detail: "\(percentage)%", systemImage: "battery.25percent", tone: .critical,
                     level: percentage <= 10 ? 1 : 0)
    }

    private func snapshot(percentage: Int, power: Bool = false) -> PowerSourceMonitor.Snapshot {
        .init(hasBattery: true, percentage: percentage,
              isCharging: power, isConnectedToPower: power)
    }
}
