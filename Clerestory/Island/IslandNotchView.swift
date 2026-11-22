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
    @Environment(IslandMessageCenter.self) private var messages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNotchHovering = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var notchArtworkImage: NSImage?

    var body: some View {
        Button {
            // IslandPresentationController handles pointer clicks on mouse-down:
            // it opens the Panel, or closes it when open. Acting again on
            // mouse-up would reopen a Panel that click just closed, so only a
            // press without the pointer, such as VoiceOver's, is handled here.
            guard !Self.isPointerActivation(NSApp.currentEvent) else { return }
            coordinator.showFromNotch(module: defaultOpenModule)
        } label: {
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

    /// Whether the button was activated by a mouse click rather than by
    /// accessibility or the keyboard.
    static func isPointerActivation(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .leftMouseDown || event.type == .leftMouseUp
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

    /// The notice or status the notch shows for its display. See IslandNotchIndicatorResolver.
    private var indicator: IslandNotchIndicator? {
        IslandNotchIndicatorResolver.resolve(display: notchDisplay.moduleID, center: messages,
                                             isDragInProgress: coordinator.isDragInProgress)
    }

    @ViewBuilder
    private var notchLeading: some View {
        let indicator = indicator
        // Artwork stays unless a warning or critical indicator needs the icon.
        if notchDisplay == .media, let image = notchArtworkImage,
           (indicator?.tint ?? .neutral) < .warning {
            NotchNowPlayingArtworkView(
                image: image,
                tint: mediaAccent.color,
                isHovered: notchIsHighlighted
            )
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else {
            IslandNotchWingIcon(systemName: indicator?.systemImage ?? notchDisplay.systemImage)
                .foregroundStyle(indicator.map { Self.tint($0.tint) } ?? .white)
                .opacity(notchIsHighlighted || indicator != nil ? 1 : 0.72)
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
        .opacity(notchIsHighlighted || indicator != nil ? 1 : 0.72)
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
        IslandNotchIndicatorResolver.accessibilityLabel(notchDisplayAccessibilityLabel, indicator: indicator)
    }

    private var notchDisplayAccessibilityLabel: String {
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
        case .fallback:
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

    /// Critical red, warning orange, progress accent, neutral white, as before statuses.
    private static func tint(_ tone: IslandStatus.Tone) -> Color {
        switch tone {
        case .critical: .red
        case .warning: .orange
        case .progress: .accentColor
        case .neutral: .white
        }
    }

}
