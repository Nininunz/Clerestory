import AppKit
import SwiftUI

/// The optional camera-housing companion. It never owns expanded transitions.
struct IslandNotchView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShelfStore.self) private var shelfStore
    @Environment(TransferStore.self) private var transferStore
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(AIUsageModuleStore.self) private var aiUsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNotchHovering = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var notchArtworkImage: NSImage?

    var body: some View {
        Button { coordinator.showFromNotch(module: defaultOpenModule) } label: {
            notchContent
        }
        .buttonStyle(.plain)
        .allowsHitTesting(settings.islandClickRevealEnabled)
        .contentShape(IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11))
        .accessibilityLabel(Text(notchAccessibilityLabel))
        .accessibilityIdentifier("island.compact")
        .help("Open Clerestory Panel")
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isNotchHovering = hovering
            }
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            notchArtworkImage = data.flatMap(NSImage.init(data:))
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
        .preferredColorScheme(.dark)
    }

    private var notchIsHighlighted: Bool { isNotchHovering || coordinator.isPointerHovering }

    private var notchContent: some View {
        ZStack(alignment: .top) {
            Color.clear
            IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                .fill(Color.black)
                .frame(height: coordinator.notchLayout?.topInset ?? 32)
            IslandNotchWingRow(cameraHousingWidth: coordinator.notchLayout?.cameraHousingWidth ?? 0,
                                 display: notchDisplay,
                                 isBackwards: { settings.notchCycleBackwards },
                                 height: coordinator.notchLayout?.topInset ?? 32) {
                notchLeading
            } trailing: {
                notchTrailing
            }
            .frame(maxWidth: .infinity)
            .frame(height: coordinator.notchLayout?.topInset ?? 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var notchLeading: some View {
        let activity = coordinator.notchPrimaryActivity()
        if notchDisplay == .media, let image = notchArtworkImage {
            NotchNowPlayingArtworkView(
                image: image,
                tint: mediaAccent.color,
                isHovered: notchIsHighlighted
            )
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else {
            IslandNotchWingIcon(systemName: activity.flatMap {
                $0.moduleID == notchDisplay.moduleID ? $0.systemImage : nil
            } ?? notchDisplay.systemImage)
                .foregroundStyle(activity?.moduleID == notchDisplay.moduleID
                                 ? activityTint(activity) : .white)
                .opacity(notchIsHighlighted || activity?.moduleID == notchDisplay.moduleID ? 1 : 0.72)
                .accessibilityHidden(true)
        }
    }

    private var notchDisplay: IslandNotchDisplay {
        settings.notchDisplay
    }

    private var notchTrailing: some View {
        Group {
            switch notchDisplay {
            case .media:
                if let snapshot = nowPlayingStore.snapshot {
                    notchMediaEqualizer(isPlaying: snapshot.isPlaying,
                                          tint: mediaAccent.color,
                                          rhythmSeed: mediaRhythmSeed)
                } else {
                    IslandNotchWingIcon(systemName: "pause")
                }
            case .transfers:
                if let task = transferStore.currentTask, task.phase.isTerminal {
                    switch task.phase {
                    case .failed, .partiallySucceeded:
                        IslandNotchWingIcon(systemName: "exclamationmark.triangle")
                    case .cancelled:
                        IslandNotchWingIcon(systemName: "xmark")
                    default:
                        IslandNotchWingIcon(systemName: "checkmark")
                    }
                } else if !transferStore.hasVisibleActivity {
                    IslandNotchWingIcon(systemName: "checkmark")
                } else if reduceMotion {
                    IslandNotchWingIcon(systemName: "arrow.triangle.2.circlepath")
                } else {
                    notchTransferSpinner
                }
            case .timer:
                if case .finished = timerStore.state {
                    IslandNotchWingIcon(systemName: "checkmark")
                } else {
                    notchTimerText(timerStore.notchRemaining)
                }
            case .aiUsage:
                if let value = aiUsageStore.notchValue {
                    IslandNotchAIValueText(value: value)
                } else {
                    IslandNotchWingIcon(systemName: "minus")
                }
            case .shelf:
                notchShelfText(shelfStore.items.count)
            case .battery:
                if powerMonitor.snapshot.hasBattery {
                    notchBatteryText(powerMonitor.snapshot.percentage)
                } else {
                    IslandNotchWingIcon(systemName: "minus")
                }
            case .fallback:
                notchFallbackSymbol
            }
        }
        .foregroundStyle(.white)
        .opacity(notchIsHighlighted || coordinator.notchPrimaryActivity()?.moduleID == notchDisplay.moduleID ? 1 : 0.72)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func notchMediaEqualizer(isPlaying: Bool, tint: Color,
                                       rhythmSeed: UInt64) -> some View {
        if !isPlaying {
            IslandNotchWingIcon(systemName: "play.fill")
        } else {
        IslandEqualizerView(isPlaying: isPlaying, reduceMotion: reduceMotion,
                            tint: tint, rhythmSeed: rhythmSeed, showsCapsule: false)
            .scaleEffect(0.92)
            .brightness(notchIsHighlighted ? 0.10 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16),
                       value: notchIsHighlighted)
        }
    }

    private var notchTransferSpinner: some View {
        IslandNotchTransferSpinner()
    }

    private func notchTimerText(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private func notchShelfText(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func notchBatteryText(_ percentage: Int) -> some View {
        IslandNotchBatteryValueText(percentage: percentage)
    }

    private var notchFallbackSymbol: some View {
        IslandNotchWingIcon(systemName: "sparkles")
    }

    private var mediaRhythmSeed: UInt64 {
        guard let snapshot = nowPlayingStore.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }

    private var notchAccessibilityLabel: String {
        switch notchDisplay {
        case .battery:
            return powerMonitor.snapshot.hasBattery
                ? String(localized: "Battery, \(powerMonitor.snapshot.percentage) percent")
                : String(localized: "No internal battery")
        case .shelf:
            return String(localized: "Clerestory Panel, \(shelfStore.items.count) shelf items")
        case .timer:
            if case .idle = timerStore.state { return String(localized: "Timer ready") }
            if case .finished = timerStore.state {
                return String(localized: "Timer finished")
            }
            return String(localized: "Timer, \(timerStore.notchRemaining) remaining")
        case .media:
            return nowPlayingStore.snapshot?.title ?? String(localized: "Nothing playing")
        case .aiUsage:
            return aiUsageStore.notchSummary ?? String(localized: "AI Usage unavailable")
        case .transfers:
            return transferStore.hasVisibleActivity ? String(localized: "Transfers") : String(localized: "No active transfers")
        default:
            if let activity = coordinator.notchPrimaryActivity(),
               activity.moduleID == notchDisplay.moduleID {
                return [activity.title, activity.detail].compactMap { $0 }.joined(separator: ", ")
            }
            return String(localized: "Clerestory Panel")
        }
    }

    private var defaultModuleDescriptor: IslandModuleDescriptor? {
        if registry.isEnabled(coordinator.selectedModule) {
            return registry.descriptors.first { $0.id == coordinator.selectedModule }
        }
        return registry.enabledDescriptors.first
    }

    private var defaultOpenModule: IslandModuleID {
        if let recent = coordinator.reentryModule(isEnabled: registry.isEnabled) { return recent }
        if let moduleID = notchDisplay.moduleID, registry.isEnabled(moduleID) {
            return moduleID
        }
        return defaultModuleDescriptor?.id ?? .quickSettings
    }

    private func activityTint(_ activity: IslandActivity?) -> Color {
        switch activity?.priority {
        case .criticalBattery: return .red
        case .systemWarning: return .orange
        case .timerFinished: return .orange
        case .transfer, .userDrag: return .accentColor
        default: return .white
        }
    }

}
