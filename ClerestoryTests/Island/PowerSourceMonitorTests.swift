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

    func testLowPowerModeToastOnlyFollowsObservedStateChanges() {
        let monitor = PowerSourceMonitor()
        var toasts: [IslandActivity] = []
        monitor.onActivity = { activity in
            if let activity, activity.id == "battery.low-power-mode" {
                toasts.append(activity)
            }
        }

        var reading = snapshot(percentage: 80)
        reading.lowPowerMode = true
        monitor.process(reading)
        monitor.process(reading)
        XCTAssertTrue(toasts.isEmpty)

        reading.lowPowerMode = false
        monitor.process(reading)
        monitor.process(reading)
        reading.lowPowerMode = true
        monitor.process(reading)
        XCTAssertEqual(toasts.map(\.title), ["Low Power Mode disabled", "Low Power Mode enabled"])
    }

    /// Turning on Low Power Mode at low battery keeps the persistent alert and
    /// shows the new mode in it, instead of replacing it with a short toast.
    func testLowPowerModeChangeKeepsTheLowBatteryAlert() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 15))
        XCTAssertEqual(activities.last??.id, "battery.low")

        var reading = snapshot(percentage: 15)
        reading.lowPowerMode = true
        monitor.process(reading)
        let latest = activities.last ?? nil
        XCTAssertEqual(latest?.id, "battery.low")
        XCTAssertNil(latest?.expiresAt)
        XCTAssertEqual(latest?.detail, "15% · Low Power Mode on")
        XCTAssertFalse(activities.contains { $0?.id == "battery.low-power-mode" })
    }

    /// Unplugging while the mode also changes publishes one activity, not two.
    func testUnplugWithModeChangePublishesOneActivity() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 80, power: true))
        activities.removeAll()
        var reading = snapshot(percentage: 80, power: false)
        reading.lowPowerMode = true
        monitor.process(reading)
        XCTAssertEqual(activities.compactMap { $0?.id }, ["battery.power-change"])
    }

    func testMissingMaximumIsUnavailable() {
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: [:]), .unavailable)
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: nil), .unavailable)
    }

    func testThresholdNotificationIsDeduplicatedWithinBand() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 21))
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 18))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 1)
        monitor.process(snapshot(percentage: 10))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 2)
    }

    func testPowerChangeExpiresAfterTwoPointFiveSeconds() {
        let now = Date(timeIntervalSince1970: 5_000)
        let monitor = PowerSourceMonitor(now: { now })
        var latest: IslandActivity?
        monitor.onActivity = { latest = $0 }
        monitor.process(snapshot(percentage: 80, power: false))
        monitor.process(snapshot(percentage: 80, power: true))
        XCTAssertEqual(latest?.id, "battery.power-change")
        XCTAssertEqual(latest?.expiresAt, now.addingTimeInterval(2.5))
    }

    func testRecoveringAboveLowBatteryThresholdClearsActivity() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 21))
        XCTAssertEqual(activities.first.flatMap { $0 }?.id, "battery.low")
        XCTAssertNil(activities.last ?? nil)
    }

    private func snapshot(percentage: Int, power: Bool = false) -> PowerSourceMonitor.Snapshot {
        .init(hasBattery: true, percentage: percentage,
              isCharging: power, isConnectedToPower: power)
    }
}
