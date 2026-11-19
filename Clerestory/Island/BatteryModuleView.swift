import SwiftUI

struct IslandBatteryView: View {
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @State private var changingLowPowerMode = false
    @State private var lowPowerModeError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: PowerSourceMonitor.Snapshot { powerMonitor.snapshot }

    var body: some View {
        VStack(spacing: IslandModuleLayout.headerSpacing) {
            IslandModuleHeader(title: "Battery", subtitle: nil, systemImage: "battery.75percent") {
                if snapshot.hasBattery {
                    Button {
                        toggleLowPowerMode()
                    } label: {
                        Image(systemName: snapshot.lowPowerMode ? "leaf.fill" : "leaf")
                            .foregroundStyle(snapshot.lowPowerMode ? Color.mint : Color.primary)
                    }
                    .buttonStyle(IslandHeaderButtonStyle())
                    .disabled(changingLowPowerMode)
                    .help("Toggle Low Power Mode")
                    .accessibilityLabel("Toggle Low Power Mode")
                    .accessibilityValue(snapshot.lowPowerMode ? Text("Low Power Mode on") : Text("Low Power Mode off"))
                }
            }
            IslandModuleScrollView(fillsViewport: true) {
                if snapshot.hasBattery {
                    VStack(alignment: .leading, spacing: 12) {
                        overview
                        if let lowPowerModeError {
                            Text(lowPowerModeError)
                                .font(.caption)
                                .foregroundStyle(IslandVisualStyle.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        BatteryPowerWaveform(samples: powerMonitor.powerHistory, currentWatts: snapshot.powerWatts)
                            .padding(12)
                            .background(batteryCardBackground)
                        batteryDetails
                            .padding(12)
                            .background(batteryCardBackground)
                    }
                    .padding(.bottom, 4)
                } else {
                    IslandEmptyState(
                        title: "No internal battery",
                        message: "This Mac does not report an internal battery.",
                        systemImage: "desktopcomputer"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toggleLowPowerMode() {
        changingLowPowerMode = true
        lowPowerModeError = nil
        Task { @MainActor in
            defer { changingLowPowerMode = false }
            do {
                try await LowPowerModeHelper.toggle()
                powerMonitor.refresh()
            } catch {
                lowPowerModeError = error.localizedDescription
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                Text(snapshot.percentage.formatted(.percent.scale(1)))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(Text("Battery charge"))
                    .accessibilityValue(Text("\(snapshot.percentage) percent"))
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label(powerStatus, systemImage: statusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IslandVisualStyle.primaryText)
                    if let estimateText {
                        Text(estimateText)
                            .font(.caption)
                            .foregroundStyle(IslandVisualStyle.secondaryText)
                    }
                }
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(IslandVisualStyle.hairline)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(batteryTint)
                            .frame(width: geometry.size.width * CGFloat(snapshot.percentage) / 100)
                    }
            }
                .frame(height: 3)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: snapshot.percentage)
            HStack {
                if let watts = snapshot.powerWatts {
                    Label(BatteryPowerFormatting.string(watts: watts), systemImage: "waveform")
                        .accessibilityLabel(Text("Battery power"))
                        .accessibilityValue(Text(BatteryPowerFormatting.string(watts: watts)))
                }
                Spacer()
                if let watts = snapshot.adapterWatts {
                    Label("\(watts) W adapter", systemImage: "powerplug")
                } else if snapshot.lowPowerMode {
                    Label("Low Power Mode", systemImage: "leaf")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(IslandVisualStyle.secondaryText)
        }
        .padding(.horizontal, 3)
    }

    private var estimateText: String? {
        let snapshot = powerMonitor.snapshot
        if let minutes = snapshot.estimatedMinutes {
            let duration = Duration.seconds(minutes * 60).formatted(
                .units(allowed: [.hours, .minutes], width: .abbreviated)
            )
            return snapshot.isCharging
                ? String(localized: "About \(duration) to full")
                : String(localized: "About \(duration) remaining")
        }
        return snapshot.isCalculatingEstimate ? String(localized: "Calculating time remaining…") : nil
    }

    private var batteryDetails: some View {
        let snapshot = powerMonitor.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            Text("Battery details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IslandVisualStyle.primaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: 3),
                      alignment: .leading, spacing: 12) {
                if let condition = snapshot.healthCondition {
                    detail("Condition", condition)
                }
                if let cycles = snapshot.cycleCount {
                    detail("Cycle count", cycles.formatted())
                }
                if let full = snapshot.fullChargeCapacity, let design = snapshot.designCapacity {
                    let ratio = (Double(full) / Double(design)).formatted(.percent.precision(.fractionLength(1)))
                    detail("Raw capacity ratio", ratio)
                }
                if let full = snapshot.fullChargeCapacity {
                    detail("Full charge capacity", String(localized: "\(full.formatted()) mAh"))
                }
                if let design = snapshot.designCapacity {
                    detail("Design capacity", String(localized: "\(design.formatted()) mAh"))
                }
                if let celsius = snapshot.temperatureCelsius {
                    let temperature = Measurement(value: celsius, unit: UnitTemperature.celsius)
                    detail("Temperature", temperature.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))))
                }
                if let millivolts = snapshot.voltageMillivolts {
                    let volts = (Double(millivolts) / 1_000).formatted(.number.precision(.fractionLength(2)))
                    detail("Voltage", String(localized: "\(volts) V"))
                }
                if let milliamps = snapshot.currentMilliamps {
                    detail("Current", String(localized: "\(milliamps.formatted()) mA"))
                }
                if let name = snapshot.adapterName {
                    detail("Power adapter", name)
                }
                if let watts = snapshot.adapterWatts {
                    detail("Adapter wattage", String(localized: "\(watts.formatted()) W"))
                }
                detail("Low Power Mode", snapshot.lowPowerMode ? String(localized: "On") : String(localized: "Off"))
            }
        }
        .font(.subheadline)
        .foregroundStyle(IslandVisualStyle.secondaryText)
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(IslandVisualStyle.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(IslandVisualStyle.primaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var batteryCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(IslandVisualStyle.cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
            }
    }

    private var statusSymbol: String {
        if powerMonitor.snapshot.isCharging { return "bolt.fill" }
        if powerMonitor.snapshot.isConnectedToPower { return "powerplug.fill" }
        return batterySymbol
    }

    private var batterySymbol: String {
        switch powerMonitor.snapshot.percentage {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        if powerMonitor.snapshot.percentage <= 10 { return .red }
        if powerMonitor.snapshot.percentage <= 20 { return .orange }
        return .mint
    }

    private var powerStatus: String {
        if powerMonitor.snapshot.isCharging { return String(localized: "Charging") }
        if powerMonitor.snapshot.isCharged { return String(localized: "Fully charged") }
        if powerMonitor.snapshot.isConnectedToPower { return String(localized: "Connected to power") }
        return String(localized: "Running on battery")
    }
}
private struct BatteryPowerWaveform: View {
    let samples: [BatteryPowerSample]
    let currentWatts: Double?

    private var scaleWatts: Double {
        let maximum = samples.map { abs($0.watts) }.max() ?? abs(currentWatts ?? 0)
        return max(10, ceil(maximum * 1.15 / 5) * 5)
    }

    private var averageWatts: Double? {
        guard !samples.isEmpty else { return currentWatts }
        return samples.map(\.watts).reduce(0, +) / Double(samples.count)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Label("Battery power history", systemImage: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.secondaryText)

                Spacer(minLength: 8)

                if let averageWatts {
                    HStack(spacing: 3) {
                        Text("Average")
                        Text(BatteryPowerFormatting.string(watts: averageWatts))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                }

                Text("Last 2 min")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
            }

            if samples.count > 1 {
                BatteryPowerCanvas(samples: samples, scaleWatts: scaleWatts)
                    .frame(height: 54)
            } else {
                Text(currentWatts == nil ? "Power reading unavailable" : "Collecting power history…")
                    .font(.caption2)
                    .foregroundStyle(IslandVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Power history"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let currentWatts else { return String(localized: "Not Available") }
        return BatteryPowerFormatting.string(watts: currentWatts)
    }
}

private struct BatteryPowerCanvas: View {
    let samples: [BatteryPowerSample]
    let scaleWatts: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let axisWidth: CGFloat = 36
            let plot = CGRect(x: axisWidth, y: 5,
                              width: max(0, size.width - axisWidth - 1),
                              height: max(0, size.height - 10))
            guard plot.width > 0, plot.height > 0 else { return }

            let zeroY = plot.midY
            drawGrid(in: plot, zeroY: zeroY, context: &context)
            guard !samples.isEmpty else { return }

            let points = samplePoints(in: plot, zeroY: zeroY)
            guard !points.isEmpty else { return }

            if points.count > 1 {
                var area = Path()
                area.move(to: CGPoint(x: points[0].x, y: zeroY))
                area.addLine(to: points[0])
                for point in points.dropFirst() {
                    area.addLine(to: point)
                }
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: zeroY))
                area.closeSubpath()

                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.green.opacity(0.24),
                            Color.green.opacity(0.02),
                            Color.cyan.opacity(0.02),
                            Color.cyan.opacity(0.22),
                        ]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    )
                )

                var line = Path()
                line.move(to: points[0])
                for point in points.dropFirst() {
                    line.addLine(to: point)
                }
                context.stroke(
                    line,
                    with: .linearGradient(
                        Gradient(colors: [.green, .mint, .cyan]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            if let latest = points.last {
                let dot = Path(ellipseIn: CGRect(x: latest.x - 3.25,
                                                y: latest.y - 3.25,
                                                width: 6.5, height: 6.5))
                let tint: Color = (samples.last?.watts ?? 0) >= 0 ? .green : .cyan
                context.fill(dot, with: .color(tint))
                context.stroke(dot, with: .color(.white.opacity(0.72)), lineWidth: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(BatteryPowerFormatting.string(watts: scaleWatts))
                .offset(y: -2)
        }
        .overlay(alignment: .bottomLeading) {
            Text(BatteryPowerFormatting.string(watts: -scaleWatts))
                .offset(y: 2)
        }
        .overlay(alignment: .leading) {
            Text("0 W")
        }
        .font(.system(size: 8, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(IslandVisualStyle.tertiaryText)
    }

    private func drawGrid(
        in plot: CGRect,
        zeroY: CGFloat,
        context: inout GraphicsContext
    ) {
        for fraction in [0.25, 0.5, 0.75] {
            let x = plot.minX + plot.width * fraction
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(.white.opacity(0.035)), lineWidth: 1)
        }

        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: plot.minX, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        context.stroke(
            zeroLine,
            with: .color(.white.opacity(0.15)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
    }

    private func samplePoints(in plot: CGRect, zeroY: CGFloat) -> [CGPoint] {
        guard let newest = samples.last?.timestamp else { return [] }
        guard let first = samples.first?.timestamp else { return [] }
        let duration = min(PowerSourceMonitor.powerHistoryDuration, max(15, newest.timeIntervalSince(first)))
        let oldest = newest.addingTimeInterval(-duration)
        let verticalRange = plot.height / 2 - 3

        return samples.map { sample in
            let elapsed = sample.timestamp.timeIntervalSince(oldest)
            let progress = min(max(elapsed / duration, 0), 1)
            let normalizedWatts = min(max(sample.watts / scaleWatts, -1), 1)
            return CGPoint(
                x: plot.minX + plot.width * CGFloat(progress),
                y: zeroY - verticalRange * CGFloat(normalizedWatts)
            )
        }
    }
}
