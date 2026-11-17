import AppKit
import SwiftUI

/// The optional camera-housing companion. It never owns expanded transitions.
struct IslandCompactView: View {
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
    @State private var isCompactHovering = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var compactArtworkImage: NSImage?

    var body: some View {
        Button { coordinator.show(module: defaultOpenModule) } label: {
            physicalNotchCompactContent
        }
        .buttonStyle(.plain)
        .allowsHitTesting(settings.islandClickRevealEnabled)
        .contentShape(IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11))
        .accessibilityLabel(Text(compactAccessibilityLabel))
        .accessibilityIdentifier("island.compact")
        .help("Open OpenYoink Island")
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isCompactHovering = hovering
            }
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            compactArtworkImage = data.flatMap(NSImage.init(data:))
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
        .preferredColorScheme(.dark)
    }

    private var compactIsHighlighted: Bool { isCompactHovering || coordinator.isPointerHovering }

    private var physicalNotchCompactContent: some View {
        ZStack(alignment: .top) {
            Color.clear
            IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                .fill(Color.black)
                .frame(height: coordinator.currentLayout?.topInset ?? 32)
            IslandCompactWingRow(cameraHousingWidth: coordinator.currentLayout?.cameraHousingWidth ?? 0,
                                 display: compactDisplay,
                                 isBackwards: { settings.compactCycleBackwards },
                                 height: coordinator.currentLayout?.topInset ?? 32) {
                compactLeading
            } trailing: {
                compactTrailing
            }
            .frame(maxWidth: .infinity)
            .frame(height: coordinator.currentLayout?.topInset ?? 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactLeading: some View {
        let activity = coordinator.compactPrimaryActivity()
        if compactDisplay == .media, let image = compactArtworkImage {
            CompactNowPlayingArtworkView(
                image: image,
                tint: mediaAccent.color,
                isHovered: compactIsHighlighted
            )
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else {
            IslandCompactWingIcon(systemName: activity.flatMap {
                $0.moduleID == compactDisplay.moduleID ? $0.systemImage : nil
            } ?? compactDisplay.systemImage)
                .foregroundStyle(activity?.moduleID == compactDisplay.moduleID
                                 ? activityTint(activity) : .white)
                .opacity(compactIsHighlighted || activity?.moduleID == compactDisplay.moduleID ? 1 : 0.72)
                .accessibilityHidden(true)
        }
    }

    private var compactDisplay: IslandCompactDisplay {
        settings.compactDisplay
    }

    private var compactTrailing: some View {
        Group {
            switch compactDisplay {
            case .media:
                if let snapshot = nowPlayingStore.snapshot {
                    compactMediaEqualizer(isPlaying: snapshot.isPlaying,
                                          tint: mediaAccent.color,
                                          rhythmSeed: mediaRhythmSeed)
                } else {
                    IslandCompactWingIcon(systemName: "pause")
                }
            case .transfers:
                if let task = transferStore.currentTask, task.phase.isTerminal {
                    switch task.phase {
                    case .failed, .partiallySucceeded:
                        IslandCompactWingIcon(systemName: "exclamationmark.triangle")
                    case .cancelled:
                        IslandCompactWingIcon(systemName: "xmark")
                    default:
                        IslandCompactWingIcon(systemName: "checkmark")
                    }
                } else if !transferStore.hasVisibleActivity {
                    IslandCompactWingIcon(systemName: "checkmark")
                } else if reduceMotion {
                    IslandCompactWingIcon(systemName: "arrow.triangle.2.circlepath")
                } else {
                    compactTransferSpinner
                }
            case .timer:
                if case .finished = timerStore.state {
                    IslandCompactWingIcon(systemName: "checkmark")
                } else {
                    compactTimerText(timerStore.compactRemaining)
                }
            case .aiUsage:
                if let value = aiUsageStore.compactValue {
                    IslandCompactAIValueText(value: value)
                } else {
                    IslandCompactWingIcon(systemName: "minus")
                }
            case .shelf:
                compactShelfText(shelfStore.items.count)
            case .battery:
                if powerMonitor.snapshot.hasBattery {
                    compactBatteryText(powerMonitor.snapshot.percentage)
                } else {
                    IslandCompactWingIcon(systemName: "minus")
                }
            case .fallback:
                compactFallbackSymbol
            }
        }
        .foregroundStyle(.white)
        .opacity(compactIsHighlighted || coordinator.compactPrimaryActivity()?.moduleID == compactDisplay.moduleID ? 1 : 0.72)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func compactMediaEqualizer(isPlaying: Bool, tint: Color,
                                       rhythmSeed: UInt64) -> some View {
        if !isPlaying {
            IslandCompactWingIcon(systemName: "play.fill")
        } else {
        IslandEqualizerView(isPlaying: isPlaying, reduceMotion: reduceMotion,
                            tint: tint, rhythmSeed: rhythmSeed, showsCapsule: false)
            .scaleEffect(0.92)
            .brightness(compactIsHighlighted ? 0.10 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16),
                       value: compactIsHighlighted)
        }
    }

    private var compactTransferSpinner: some View {
        IslandCompactTransferSpinner()
    }

    private func compactTimerText(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private func compactShelfText(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func compactBatteryText(_ percentage: Int) -> some View {
        IslandCompactBatteryValueText(percentage: percentage)
    }

    private var compactFallbackSymbol: some View {
        IslandCompactWingIcon(systemName: "sparkles")
    }

    private var mediaRhythmSeed: UInt64 {
        guard let snapshot = nowPlayingStore.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }

    private var compactAccessibilityLabel: String {
        switch compactDisplay {
        case .battery:
            return powerMonitor.snapshot.hasBattery
                ? String(localized: "Battery, \(powerMonitor.snapshot.percentage) percent")
                : String(localized: "No internal battery")
        case .shelf:
            return String(localized: "OpenYoink Island, \(shelfStore.items.count) shelf items")
        case .timer:
            if case .idle = timerStore.state { return String(localized: "Timer ready") }
            if case .finished = timerStore.state {
                return String(localized: "Timer finished")
            }
            return String(localized: "Timer, \(timerStore.compactRemaining) remaining")
        case .media:
            return nowPlayingStore.snapshot?.title ?? String(localized: "Nothing playing")
        case .aiUsage:
            return aiUsageStore.compactSummary ?? String(localized: "AI Usage unavailable")
        case .transfers:
            return transferStore.hasVisibleActivity ? String(localized: "Transfers") : String(localized: "No active transfers")
        default:
            if let activity = coordinator.compactPrimaryActivity(),
               activity.moduleID == compactDisplay.moduleID {
                return [activity.title, activity.detail].compactMap { $0 }.joined(separator: ", ")
            }
            return String(localized: "OpenYoink Island")
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
        if let moduleID = compactDisplay.moduleID, registry.isEnabled(moduleID) {
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
