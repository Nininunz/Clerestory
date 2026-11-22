import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryElectricalSample: Equatable, Sendable {
    let voltageMillivolts: Int64
    let currentMilliamps: Int64

    func signedPowerWatts(isCharging: Bool, isConnectedToPower: Bool) -> Double {
        let rawWatts = Double(voltageMillivolts) * Double(currentMilliamps) / 1_000_000
        if isCharging { return abs(rawWatts) }
        if !isConnectedToPower { return -abs(rawWatts) }
        return rawWatts
    }
}

struct BatteryPowerSample: Equatable, Sendable {
    let timestamp: Date
    let watts: Double
}

enum BatteryElectricalReader {
    private static let registryCurrentKeys = ["InstantAmperage", "Amperage"]

    static func sample(
        powerSourceDescription: [String: Any],
        registryProperties: [String: Any]? = nil
    ) -> BatteryElectricalSample? {
        let sourceVoltage = integer(powerSourceDescription[kIOPSVoltageKey])
        let sourceCurrent = integer(powerSourceDescription[kIOPSCurrentKey])
        let registryVoltage = integer(registryProperties?["Voltage"])
        // Apple silicon can report a zero IOPS current while the battery
        // registry still publishes a live instantaneous value.
        let registryCurrents = registryCurrentKeys.compactMap {
            integer(registryProperties?[$0])
        }
        let registryCurrent = registryCurrents.first(where: { $0 != 0 })
            ?? registryCurrents.first

        guard let voltage = validVoltage(sourceVoltage) ?? validVoltage(registryVoltage) else {
            return nil
        }
        let current: Int64?
        if let sourceCurrent, sourceCurrent != 0 {
            current = sourceCurrent
        } else {
            current = registryCurrent ?? sourceCurrent
        }
        guard let current, validCurrent(current) else { return nil }
        return .init(voltageMillivolts: voltage, currentMilliamps: current)
    }

    static func readRegistryProperties(serviceName: String = "AppleSmartBattery") -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceNameMatching(serviceName)
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func validVoltage(_ value: Int64?) -> Int64? {
        guard let value, value > 0, value <= 100_000 else { return nil }
        return value
    }

    private static func validCurrent(_ value: Int64) -> Bool {
        value != Int64.min && abs(value) <= 100_000
    }
}

enum BatteryPowerFormatting {
    static func string(watts: Double) -> String {
        let normalized = abs(watts) < 0.05 ? 0 : watts
        let format = normalized == 0 ? "%.1f W" : "%+.1f W"
        return String(format: format, locale: .current, normalized)
    }
}

@MainActor
@Observable
final class PowerSourceMonitor: IslandModule {
    static let powerHistoryDuration: TimeInterval = 2 * 60
    static let maximumPowerHistoryCount = 60

    struct Snapshot: Equatable, Sendable {
        var hasBattery: Bool
        var percentage: Int
        var isCharging: Bool
        var isConnectedToPower: Bool
        var powerWatts: Double? = nil
        var isCharged = false
        var estimatedMinutes: Int? = nil
        var isCalculatingEstimate = false
        var cycleCount: Int? = nil
        var temperatureCelsius: Double? = nil
        var voltageMillivolts: Int64? = nil
        var currentMilliamps: Int64? = nil
        var fullChargeCapacity: Int? = nil
        var designCapacity: Int? = nil
        /// Battery health as System Settings shows it ("Maximum Capacity").
        /// Nil when the battery doesn't report it as a percentage, as on Intel Macs.
        var maximumCapacityPercent: Int? = nil
        var healthCondition: String? = nil
        var adapterName: String? = nil
        var adapterWatts: Int? = nil
        var lowPowerMode = false

        /// Plugged in but neither charging nor full: macOS is holding the
        /// charge, for example for Optimized Battery Charging or a charge limit.
        var isChargingOnHold: Bool {
            hasBattery && isConnectedToPower && !isCharging && !isCharged
        }

        static let unavailable = Snapshot(hasBattery: false,
                                          percentage: 0,
                                          isCharging: false,
                                          isConnectedToPower: false,
                                          powerWatts: nil)
    }

    let descriptor = IslandModuleRegistry.batteryDescriptor

    @ObservationIgnored
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    private let nowProvider: @MainActor () -> Date
    private let fullChargeAlertEnabled: @MainActor () -> Bool
    private let lowBatteryWarningPercent: @MainActor () -> Int
    private(set) var snapshot: Snapshot = .unavailable
    private(set) var powerHistory: [BatteryPowerSample] = []
    private(set) var isRunning = false
    @ObservationIgnored private let isSelectedAndExpanded: @MainActor () -> Bool
    @ObservationIgnored private let samplingAllowed: @MainActor () -> Bool
    @ObservationIgnored private let snapshotProvider: @MainActor () -> Snapshot
    @ObservationIgnored nonisolated(unsafe) private var resourceToken: NSObjectProtocol?
    /// Where Battery sets its "low" status and posts its power notices.
    @ObservationIgnored var messenger: ModuleMessenger = .inert
    var onStateChange: (@MainActor () -> Void)?

    init(now: @escaping @MainActor () -> Date = Date.init,
         isSelectedAndExpanded: @escaping @MainActor () -> Bool = { false },
         samplingAllowed: @escaping @MainActor () -> Bool = { ResourceUsageState.shared.samplingAllowed },
         snapshotProvider: @escaping @MainActor () -> Snapshot = { PowerSourceMonitor.readSnapshot() },
         fullChargeAlertEnabled: @escaping @MainActor () -> Bool = { false },
         lowBatteryWarningPercent: @escaping @MainActor () -> Int = { SettingsStore.defaultLowBatteryWarningPercent }) {
        self.nowProvider = now
        self.isSelectedAndExpanded = isSelectedAndExpanded
        self.samplingAllowed = samplingAllowed
        self.snapshotProvider = snapshotProvider
        self.fullChargeAlertEnabled = fullChargeAlertEnabled
        self.lowBatteryWarningPercent = lowBatteryWarningPercent
    }

    deinit {
        pollingTask?.cancel()
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = ResourceUsageState.shared
        resourceToken = NotificationCenter.default.addObserver(forName: .clerestoryResourcePolicyDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }
        restartPolling()
    }

    private func registerPowerNotificationsIfNeeded() {
        // Desktops and external-only displays have no battery transitions to
        // observe. Keep the unavailable snapshot visible without retaining an
        // otherwise idle run-loop source.
        guard snapshot.hasBattery, runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
            }
        }, context) else { return }
        let source = unmanaged.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isRunning, samplingAllowed() else { return }
        refresh()
        guard snapshot.hasBattery else { return }
        registerPowerNotificationsIfNeeded()
        pollingTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                let interval = ResourceUsagePolicy.batteryInterval(isExpanded: self.isSelectedAndExpanded(),
                                                                   isConstrained: ResourceUsageState.shared.isConstrained)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self.refresh()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
        resourceToken = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
        messenger.setStatuses([])
    }

    func refresh() {
        guard isRunning, samplingAllowed() else { return }
        process(snapshotProvider())
    }

    /// Internal deterministic seam for pure unit tests and future power-event
    /// adapters. Production still enters only through the IOKit notification.
    func process(_ current: Snapshot) {
        let previous = snapshot
        snapshot = current
        recordPowerSample(from: current)
        updateMessages(previous: previous, current: current)
        onStateChange?()
    }

    private func recordPowerSample(from snapshot: Snapshot) {
        guard let watts = snapshot.powerWatts, watts.isFinite else { return }
        let timestamp = nowProvider()
        let sample = BatteryPowerSample(timestamp: timestamp, watts: watts)

        // Power-source notifications can arrive next to the regular poll. Fold
        // near-simultaneous readings together so the chart keeps a steady pace.
        if let last = powerHistory.last,
           timestamp.timeIntervalSince(last.timestamp) < 0.5 {
            powerHistory[powerHistory.count - 1] = sample
        } else {
            powerHistory.append(sample)
        }

        let cutoff = timestamp.addingTimeInterval(-Self.powerHistoryDuration)
        powerHistory.removeAll { $0.timestamp < cutoff }
        if powerHistory.count > Self.maximumPowerHistoryCount {
            powerHistory.removeFirst(
                powerHistory.count - Self.maximumPowerHistoryCount
            )
        }
    }

    static func snapshot(
        from description: [String: Any]?,
        registryProperties: [String: Any]? = nil,
        packProperties: [String: Any]? = nil,
        adapterProperties: [String: Any]? = nil,
        lowPowerMode: Bool = false
    ) -> Snapshot {
        guard let description else { return .unavailable }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 0
        guard maximum > 0 else { return .unavailable }
        let percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        let state = description[kIOPSPowerSourceStateKey] as? String
        let onAC = state == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        // For a few seconds after wake, macOS reports zero current while the
        // Mac runs on battery. Treat that as no reading rather than 0 W.
        let electrical = BatteryElectricalReader.sample(
            powerSourceDescription: description,
            registryProperties: registryProperties
        ).flatMap { onAC || $0.currentMilliamps != 0 ? $0 : nil }
        let charged = description[kIOPSIsChargedKey] as? Bool
            ?? (onAC && !charging && percentage == 100)
        let estimate = charging ? description[kIOPSTimeToFullChargeKey] as? Int
            : state == kIOPSBatteryPowerValue ? description[kIOPSTimeToEmptyKey] as? Int : nil
        let data = registryProperties?["BatteryData"] as? [String: Any]
        let packData = packProperties?["BatteryData"] as? [String: Any]
        let registryAdapter = registryProperties?["AdapterDetails"] as? [String: Any]
        let registryTemperature = (packData?["Temperature"] as? NSNumber)
            ?? (registryProperties?["Temperature"] as? NSNumber)
        let temperature = registryTemperature.map { $0.doubleValue / 100 }
            ?? (description[kIOPSTemperatureKey] as? NSNumber)?.doubleValue

        return Snapshot(
            hasBattery: true,
            percentage: percentage,
            isCharging: charging,
            isConnectedToPower: onAC,
            powerWatts: electrical?.signedPowerWatts(isCharging: charging, isConnectedToPower: onAC),
            isCharged: charged,
            estimatedMinutes: estimate.flatMap { (0..<65_535).contains($0) ? $0 : nil },
            isCalculatingEstimate: estimate == -1,
            cycleCount: registryProperties?["CycleCount"] as? Int,
            temperatureCelsius: temperature.flatMap { (-20...100).contains($0) ? $0 : nil },
            voltageMillivolts: electrical?.voltageMillivolts,
            currentMilliamps: electrical?.currentMilliamps,
            fullChargeCapacity: positiveCapacity(data?["FullChargeCapacity"], data?["AppleRawMaxCapacity"],
                                                 registryProperties?["AppleRawMaxCapacity"]),
            designCapacity: positiveCapacity(data?["DesignCapacity"], registryProperties?["DesignCapacity"]),
            maximumCapacityPercent: maximumCapacityPercent(
                registryProperties?["MaxCapacity"],
                design: positiveCapacity(data?["DesignCapacity"], registryProperties?["DesignCapacity"])),
            healthCondition: description[kIOPSBatteryHealthConditionKey] as? String
                ?? description[kIOPSBatteryHealthKey] as? String,
            adapterName: onAC ? (registryAdapter?["Name"] as? String) : nil,
            adapterWatts: onAC ? positiveCapacity(adapterProperties?[kIOPSPowerAdapterWattsKey],
                                                 registryAdapter?["Watts"]) : nil,
            lowPowerMode: lowPowerMode
        )
    }

    /// On Apple silicon the battery's `MaxCapacity` is the health percentage
    /// System Settings shows. On Intel Macs it is a capacity in mAh, so only a
    /// value of at most 100 next to a design capacity in mAh counts.
    static func maximumCapacityPercent(_ value: Any?, design: Int?) -> Int? {
        guard let percent = value as? Int, (1...100).contains(percent),
              let design, design > 100 else { return nil }
        return percent
    }

    private static func positiveCapacity(_ values: Any?...) -> Int? {
        values.compactMap { $0 as? Int }.first { $0 > 0 }
    }

    private static func readSnapshot() -> Snapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }

        let registryProperties = BatteryElectricalReader.readRegistryProperties()
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return snapshot(
                from: description,
                registryProperties: registryProperties,
                packProperties: BatteryElectricalReader.readRegistryProperties(serviceName: "AppleSmartBatteryPack"),
                adapterProperties: onAC ? IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] : nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return .unavailable
    }

    /// How long Battery's power, Low Power Mode and full-charge notices stay on screen.
    static let powerNoticeDuration: TimeInterval = 2.5

    /// Every sample sets the whole status set, so "low" is there exactly while the battery is
    /// low, whatever notices come and go. The center announces it once when it is raised.
    private func updateMessages(previous: Snapshot, current: Snapshot) {
        messenger.setStatuses(current.hasBattery
            ? Self.statuses(for: current, lowThreshold: lowBatteryWarningPercent()) : [])
        guard current.hasBattery, previous.hasBattery else { return }
        if previous.isConnectedToPower != current.isConnectedToPower {
            let title = current.isConnectedToPower
                ? String(localized: "Power connected")
                : String(localized: "Running on battery")
            let percentage = "\(current.percentage)%"
            messenger.post(IslandNotice(
                key: "power",
                title: IslandStatus.pillText(title: title, detail: percentage),
                detail: IslandStatus.spokenText(title: title, detail: percentage),
                systemImage: current.isConnectedToPower ? "bolt.fill" : "battery.75percent",
                duration: Self.powerNoticeDuration
            ))
        } else if previous.lowPowerMode != current.lowPowerMode {
            messenger.post(IslandNotice(
                key: "low-power-mode",
                title: current.lowPowerMode
                    ? String(localized: "Low Power Mode enabled")
                    : String(localized: "Low Power Mode disabled"),
                systemImage: current.lowPowerMode ? "leaf.fill" : "leaf",
                duration: Self.powerNoticeDuration
            ))
        } else if fullChargeAlertEnabled(),
                  previous.percentage < 100,
                  current.percentage == 100 {
            messenger.post(IslandNotice(
                key: "full",
                title: String(localized: "Battery fully charged"),
                tone: .success,
                systemImage: "battery.100percent",
                duration: Self.powerNoticeDuration
            ))
        }
    }

    /// Applies a changed low-battery warning setting now instead of at the next sample.
    func refreshStatuses() {
        guard isRunning else { return }
        messenger.setStatuses(snapshot.hasBattery
            ? Self.statuses(for: snapshot, lowThreshold: lowBatteryWarningPercent()) : [])
    }

    /// "low" while the battery is at `lowThreshold` (the setting, 20% by default) or less.
    /// Both bands are critical, so the notch stays red. "Battery critically low" at 10% or
    /// less is level 1, so falling into it raises the status again, while charging back out
    /// of it (level 0, "Battery low") is silent.
    static func statuses(for snapshot: Snapshot,
                         lowThreshold: Int = SettingsStore.defaultLowBatteryWarningPercent) -> [IslandStatus] {
        guard snapshot.hasBattery, snapshot.percentage <= max(lowThreshold, 10) else { return [] }
        let isCritical = snapshot.percentage <= 10
        return [IslandStatus(
            key: "low",
            title: isCritical
                ? String(localized: "Battery critically low")
                : String(localized: "Battery low"),
            detail: "\(snapshot.percentage)%",
            systemImage: "battery.25percent",
            tone: .critical,
            level: isCritical ? 1 : 0
        )]
    }
}

#if DEBUG
// Isolated, non-running fixtures for the module preview catalog. Never used by app startup.
extension PowerSourceMonitor {
    static func preview(snapshot: Snapshot) -> PowerSourceMonitor {
        let store = PowerSourceMonitor(samplingAllowed: { false })
        store.snapshot = snapshot
        return store
    }
}
#endif
