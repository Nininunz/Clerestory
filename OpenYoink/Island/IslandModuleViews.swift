import AppKit
import SwiftUI

struct ShelfPresentationRootView: View {
    let presentationStyle: ShelfPresentationStyle
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if presentationStyle == .island {
                IslandRootView(
                    onPerformRecovery: onPerformRecovery,
                    onOpenSettings: onOpenSettings
                )
            } else {
                ShelfView()
            }
        }
    }
}

struct IslandRootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShelfStore.self) private var shelfStore
    @Environment(TransferStore.self) private var transferStore
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(IslandModuleContainer.self) private var moduleContainer
    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(SystemStatusModuleStore.self) private var systemStatusStore
    @Environment(AIUsageModuleStore.self) private var aiUsageStore
    @Environment(FavoriteFoldersStore.self) private var favoriteFoldersStore
    @Environment(ClipboardHistoryStore.self) private var clipboardHistoryStore
    @Environment(FavoriteFolderDropCoordinator.self) private var folderCopy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompactHovering = false
    @State private var isCompactMediaControlHovering = false
    @State private var isCollapseControlHovering = false
    @State private var isSettingsControlHovering = false
    @State private var isSendingCompactMediaCommand = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var compactArtworkImage: NSImage?
    @State private var renderedSurfaceState: IslandSurfaceState = .compact
    @State private var activeSurfaceAnimation: UUID?
    @State private var requestedSurfaceTransitionID: UInt64 = 0

    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            if renderedSurfaceState.isExpanded {
                expandedContent
                    .frame(width: coordinator.currentLayout?.expandedFrame.width,
                           height: coordinator.currentLayout?.expandedFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0.82,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        ),
                        removal: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        )
                    ))
            } else {
                floatingAwareCompactContent
                    // Upper bounds only: a fixed size here becomes the hosting
                    // window's minimum size, and the floating idle dot needs
                    // the panel to shrink below the pill (issue #11).
                    .frame(minWidth: 0,
                           maxWidth: coordinator.currentLayout?.compactFrame.width,
                           minHeight: 0,
                           maxHeight: coordinator.currentLayout?.compactFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island.root")
        .alert("File Already Exists", isPresented: Binding(
            get: { folderCopy.conflictName != nil },
            set: { if !$0 { folderCopy.decideConflict(.cancel) } }
        )) {
            Button("Keep Both") { folderCopy.decideConflict(.keepBoth) }
            Button("Skip") { folderCopy.decideConflict(.skip) }
            Button("Cancel Copy", role: .cancel) { folderCopy.decideConflict(.cancel) }
        } message: {
            Text((folderCopy.conflictName ?? "") + "\n" + String(localized: "The existing file will not be overwritten."))
        }
        .onChange(of: coordinator.surfaceTransitionID, initial: true) {
            renderSurface(coordinator.surfaceState)
        }
        .onChange(of: settings.islandModuleConfiguration, initial: true) {
            registry.apply(settings: settings)
            moduleContainer.apply(
                configuration: settings.islandModuleConfiguration,
                isActive: settings.islandEnabled
            )
            if !registry.isEnabled(coordinator.selectedModule),
               let fallback = visibleModuleDescriptors.first?.id
                    ?? registry.enabledDescriptors.first?.id {
                coordinator.selectedModule = fallback
            }
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            compactArtworkImage = data.flatMap(NSImage.init(data:))
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
        .onChange(of: coordinator.selectedModule) { samplingContextChanged() }
        .onChange(of: coordinator.surfaceState) { samplingContextChanged() }
    }

    private func renderSurface(_ state: IslandSurfaceState) {
        requestedSurfaceTransitionID = coordinator.surfaceTransitionID
        if reduceMotion {
            activeSurfaceAnimation = nil
            renderedSurfaceState = state
            coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
            return
        }
        guard renderedSurfaceState != state else {
            // A coalesced close/open/close may leave the same fold running.
            // Its real completion must still precede the host-window resize.
            if activeSurfaceAnimation == nil {
                coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
            }
            return
        }
        let animationID = UUID()
        activeSurfaceAnimation = animationID
        withAnimation(surfaceAnimation(for: state), completionCriteria: .removed) {
            renderedSurfaceState = state
        } completion: {
            guard activeSurfaceAnimation == animationID else { return }
            activeSurfaceAnimation = nil
            coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
        }
    }

    private func surfaceAnimation(for state: IslandSurfaceState) -> Animation {
        if state.isExpanded {
            return .smooth(
                duration: IslandMotion.expandContentDuration,
                extraBounce: 0
            )
        }
        return .smooth(
            duration: IslandMotion.collapseContentDuration,
            extraBounce: 0
        )
    }

    private func samplingContextChanged() {
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        if coordinator.surfaceState.isExpanded, coordinator.selectedModule == .media {
            nowPlayingStore.refresh()
        }
    }

    private var collapsedSurfaceHeight: CGFloat {
        coordinator.currentLayout?.compactFrame.height
            ?? IslandGeometryResolver.floatingCompactSize.height
    }

    private var collapsedSurfaceWidth: CGFloat {
        coordinator.currentLayout?.compactFrame.width
            ?? IslandGeometryResolver.floatingCompactSize.width
    }

    /// Displays without a notch can shrink the idle pill into a dot or hide
    /// it entirely (issue #11). The window controller sizes the panel.
    private var floatingAwareCompactContent: some View {
        let presentation = hasPhysicalNotch ? .capsule : coordinator.floatingPresentation
        return ZStack(alignment: .top) {
            switch presentation {
            case .capsule:
                compactContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.5, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.08, anchor: .top))
                    ))
            case .dot:
                floatingIdleDot
                    .transition(.opacity.combined(with: .scale(scale: 0.3, anchor: .top)))
            case .hidden:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: presentation)
    }

    private var floatingIdleDot: some View {
        let activity = coordinator.compactPrimaryActivity()
        let ring = activity?.moduleID == .media ? mediaAccent.color : activityTint(activity)
        let diameter = IslandGeometryResolver.floatingDotDiameter
        return Circle()
            .fill(Color.black.opacity(0.92))
            .overlay {
                Circle().strokeBorder(ring.opacity(activity == nil ? 0.32 : 0.75), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .padding(.top, (IslandGeometryResolver.floatingDotHitSize.height - diameter) / 2)
            .accessibilityElement()
            .accessibilityLabel(Text(compactAccessibilityLabel))
            .accessibilityHint(Text("Open OpenYoink Island"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard settings.islandClickRevealEnabled else { return }
                coordinator.show(module: defaultOpenModule)
            }
    }

    private var compactContent: some View {
        ZStack {
            Button {
                coordinator.show(module: defaultOpenModule)
            } label: {
                if hasPhysicalNotch {
                    physicalNotchCompactContent
                } else {
                    HStack(spacing: 8) {
                        compactLeading
                        compactSummary
                        Spacer(minLength: 4)
                        compactTrailing
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(settings.islandClickRevealEnabled)
            .accessibilityHidden(!settings.islandClickRevealEnabled)
            .contentShape(compactHitShape)
            .accessibilityLabel(Text(compactAccessibilityLabel))
            .accessibilityHint(Text("Open OpenYoink Island"))
            .help(Text("Open OpenYoink Island"))

        }
        .contentShape(compactHitShape)
        .background {
            if !hasPhysicalNotch {
                compactSurfaceShape
                    .fill(Color.black.opacity(0.94))
            }
        }
        .overlay {
            if !hasPhysicalNotch && compactIsHighlighted {
                compactSurfaceShape
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            } else if !hasPhysicalNotch {
                compactSurfaceShape
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .onHover { hovering in
            if reduceMotion {
                isCompactHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactHovering = hovering
                }
            }
        }
    }

    private var physicalNotchCompactContent: some View {
        ZStack(alignment: .top) {
            Color.clear
            IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                .fill(Color.black)
                .frame(height: coordinator.currentLayout?.topInset ?? 32)
            IslandCompactWingRow(cameraHousingWidth: coordinator.currentLayout?.cameraHousingWidth ?? 0) {
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
        if IslandDragFeedback.isEnabled && hasPhysicalNotch && coordinator.isFileDragNearby {
            compactDragCueSymbol("tray.and.arrow.down.fill")
        } else if compactDisplay == .media, let image = compactArtworkImage {
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
                .opacity(compactIsHighlighted || activity != nil ? 1 : 0.72)
                .accessibilityHidden(true)
        }
    }

    private var compactDisplay: IslandCompactDisplay {
        let timerIsActive: Bool
        let timerIsFinished: Bool
        switch timerStore.state {
        case .running, .paused:
            timerIsActive = registry.isEnabled(.timer)
            timerIsFinished = false
        case .finished:
            timerIsActive = false
            timerIsFinished = registry.isEnabled(.timer)
        case .idle:
            timerIsActive = false
            timerIsFinished = false
        }
        return IslandCompactDisplay.choose(
            primaryModule: coordinator.compactPrimaryActivity()?.moduleID,
            hasMedia: nowPlayingStore.snapshot != nil,
            hasTransfer: transferStore.hasVisibleActivity,
            timerIsActive: timerIsActive,
            timerIsFinished: timerIsFinished,
            hasAIValue: aiUsageStore.compactValue != nil,
            shelfEnabled: registry.isEnabled(.shelf),
            shelfCount: shelfStore.items.count,
            batteryEnabled: registry.isEnabled(.battery),
            hasBattery: powerMonitor.snapshot.hasBattery
        )
    }

    private var compactTrailing: some View {
        Group {
            if IslandDragFeedback.isEnabled && hasPhysicalNotch && coordinator.isFileDragNearby {
                compactDragCueSymbol("arrow.down")
            } else {
                switch compactDisplay {
                case .media:
                    if let snapshot = nowPlayingStore.snapshot {
                        compactMediaEqualizer(isPlaying: snapshot.isPlaying,
                                              tint: mediaAccent.color,
                                              rhythmSeed: mediaRhythmSeed)
                    }
                case .transfers:
                    if reduceMotion {
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
                    }
                case .shelf:
                    compactShelfText(shelfStore.items.count)
                case .battery:
                    compactBatteryText(powerMonitor.snapshot.percentage)
                case .fallback:
                    compactFallbackSymbol
                }
            }
        }
        .foregroundStyle(.white)
        .opacity(compactIsHighlighted || coordinator.compactPrimaryActivity() != nil ? 1 : 0.72)
        .accessibilityHidden(true)
    }

    private func compactDragCueSymbol(_ name: String) -> some View {
        IslandCompactWingIcon(systemName: name)
            .foregroundStyle(Color.accentColor)
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

    // Preserved for a possible future compact playback control; not mounted in compactContent.
    @ViewBuilder
    private var compactMediaTransportOverlay: some View {
        if coordinator.compactPrimaryActivity()?.moduleID == .media,
           nowPlayingStore.snapshot != nil,
           nowPlayingStore.supportsTransportControls {
            if hasPhysicalNotch {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: IslandGeometryResolver.compactWingWidth,
                               height: coordinator.currentLayout?.topInset ?? 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: 44, height: 38)
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var compactMediaTransportButton: some View {
        let snapshot = nowPlayingStore.snapshot
        let isPlaying = snapshot?.isPlaying == true
        let showsTransportControl = isCompactMediaControlHovering || compactIsHighlighted
        let actionLabel = isPlaying ? String(localized: "Pause") : String(localized: "Play")
        return Button {
            guard !isSendingCompactMediaCommand else { return }
            Task {
                isSendingCompactMediaCommand = true
                _ = await nowPlayingStore.send(.togglePlayPause)
                isSendingCompactMediaCommand = false
            }
        } label: {
            compactMediaTransportLabel(isPlaying: isPlaying,
                                       showsControl: showsTransportControl,
                                       isSending: isSendingCompactMediaCommand,
                                       tint: mediaAccent.color,
                                       rhythmSeed: mediaRhythmSeed)
                .offset(x: hasPhysicalNotch ? -5 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!nowPlayingStore.supportsTransportControls
                  || isSendingCompactMediaCommand)
        .opacity(nowPlayingStore.supportsTransportControls ? 1 : 0.46)
        .onHover { hovering in
            if reduceMotion {
                isCompactMediaControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactMediaControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text(actionLabel))
        .accessibilityHint(Text("Control playback without expanding the Island"))
        .help(Text(actionLabel))
    }

    private func compactMediaTransportLabel(isPlaying: Bool, showsControl: Bool,
                                            isSending: Bool, tint: Color,
                                            rhythmSeed: UInt64) -> some View {
        ZStack {
            IslandEqualizerView(isPlaying: isPlaying, reduceMotion: reduceMotion,
                                tint: tint, rhythmSeed: rhythmSeed, showsCapsule: false)
                .scaleEffect(showsControl ? 0.84 : 0.92)
                .opacity(showsControl ? 0 : 1)

            Group {
                if isSending {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 30, height: 22)
            .scaleEffect(showsControl ? 1 : 0.82)
            .opacity(showsControl ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var mediaRhythmSeed: UInt64 {
        guard let snapshot = nowPlayingStore.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }

    @ViewBuilder
    private var compactSummary: some View {
        if let activity = coordinator.compactPrimaryActivity(),
           activity.moduleID == compactDisplay.moduleID {
            VStack(alignment: .leading, spacing: 0) {
                Text(activity.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Group {
                switch compactDisplay {
                case .media: Text("Now Playing")
                case .transfers: Text("Transfers")
                case .timer: Text("Timer")
                case .aiUsage: Text(aiUsageStore.compactSummary ?? "AI Usage")
                case .shelf: Text("Shelf")
                case .battery: Text("Battery")
                case .fallback: Text("OpenYoink Island")
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if hasPhysicalNotch {
                physicalNotchModuleStrip
            } else {
                floatingIslandToolbar
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
            }
            GeometryReader { geometry in
                let pages = [coordinator.selectedModule] + (coordinator.shortcutSwipeTarget.map { [$0] } ?? [])
                ZStack {
                    ForEach(pages, id: \.self) { module in
                        modulePage(module)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .offset(x: reduceMotion ? 0 : coordinator.shortcutSwipeOffset
                                + (module == coordinator.selectedModule ? 0
                                   : CGFloat(coordinator.shortcutSwipeDirection) * geometry.size.width))
                            .opacity(reduceMotion && module != coordinator.selectedModule ? 0 : 1)
                            .allowsHitTesting(module == coordinator.selectedModule && coordinator.shortcutSwipeOffset == 0)
                    }
                }
            }
                .clipped()
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .contentShape(expandedSurfaceShape)
        .background {
            ZStack {
                Color.black
                LinearGradient(
                    colors: [Color.white.opacity(0.035), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .clipShape(expandedSurfaceShape)
        }
        .overlay {
            if !hasPhysicalNotch {
                expandedSurfaceShape
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        // A physical notch is attached to the display rather than floating
        // above it, so an elevation shadow reads as a translucent rectangle.
        // Keep elevation only for the fallback pill on displays without a notch.
        .shadow(color: hasPhysicalNotch ? .clear : .black.opacity(0.30),
                radius: hasPhysicalNotch ? 0 : 16,
                y: hasPhysicalNotch ? 0 : 8)
        .contextMenu {
            Button("Settings…") {
                openSettings()
            }
            Button(pinLabel) {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            }
            Button("Collapse Island") {
                coordinator.collapse()
            }
        }
    }

    private var hasPhysicalNotch: Bool {
        coordinator.currentLayout?.hasPhysicalNotch == true
    }

    private var compactIsHighlighted: Bool {
        isCompactHovering || coordinator.isPointerHovering
    }

    private var compactSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 13)
    }

    private var compactHitShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch,
                           cornerRadius: hasPhysicalNotch ? 11 : 13)
    }

    private var expandedSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 26)
    }

    private var physicalNotchModuleStrip: some View {
        let slots = pinnedModuleSlots
        let leadingSlots = Array(slots.prefix(4))
        let trailingSlots = Array(slots.dropFirst(4))
        let notchWidth = coordinator.currentLayout?.cameraHousingWidth ?? 0
        let notchHeight = coordinator.currentLayout?.topInset ?? 32
        let stripHeight = notchHeight
            + IslandGeometryResolver.physicalNotchClickExtension

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(leadingSlots.indices, id: \.self) { index in
                        if let descriptor = leadingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Color.clear
                    .frame(width: notchWidth)
                    .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(trailingSlots.indices, id: \.self) { index in
                        if let descriptor = trailingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
                    }
                    // Quick Settings owns the final slot, outside user reordering.
                    settingsButton(size: 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)

            // The hardware camera housing itself cannot receive mouse events.
            // Give its small visible chin an explicit, top-most collapse target
            // instead of relying on a background button underneath the module
            // tabs. This also prevents the adjacent media tab from stealing a
            // click intended for the center of the Island.
            Button {
                coordinator.collapse()
            } label: {
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    Capsule()
                        .fill(Color.white.opacity(isCollapseControlHovering ? 0.50 : 0.22))
                        .frame(width: 30, height: 3)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(width: notchWidth, height: stripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if reduceMotion {
                    isCollapseControlHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isCollapseControlHovering = hovering
                    }
                }
            }
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: stripHeight)
    }

    private func physicalNotchModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.72))
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
                }
                .opacity(isEnabled || isSelected ? 1 : 0.46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private var floatingIslandToolbar: some View {
        HStack(spacing: 10) {
            moduleNavigation
            Spacer(minLength: 4)

            Button {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            } label: {
                Image(systemName: coordinator.surfaceState == .pinned
                      ? "pin.fill" : "pin")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pinLabel))
            .help(Text(pinLabel))

            Button {
                coordinator.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: 38)
    }

    private func settingsButton(size: CGFloat) -> some View {
        Button {
            coordinator.selectedModule = .quickSettings
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: size == 30 ? 13 : 11, weight: .semibold))
                .foregroundStyle(coordinator.selectedModule == .quickSettings
                                 ? Color.accentColor : Color.white.opacity(isSettingsControlHovering ? 1 : 0.72))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(Color.white.opacity(coordinator.selectedModule == .quickSettings ? 0.10 : (isSettingsControlHovering ? 0.14 : 0.07)))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isSettingsControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isSettingsControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text("Quick Settings"))
        .help(Text("Quick Settings"))
        .modifier(IslandSelectedAccessibilityModifier(selected: coordinator.selectedModule == .quickSettings))
    }

    private func openSettings() {
        // The Island panel intentionally sits above ordinary app windows.
        // Collapse it before presenting Settings so it cannot cover the
        // controls the user just asked to reach.
        coordinator.collapse()
        onOpenSettings?()
    }

    private var pinLabel: String {
        coordinator.surfaceState == .pinned
            ? String(localized: "Unpin Island")
            : String(localized: "Pin Island")
    }

    private var moduleNavigation: some View {
        HStack(spacing: 3) {
            ForEach(pinnedModuleSlots.indices, id: \.self) { index in
                if let descriptor = pinnedModuleSlots[index] {
                    floatingModuleButton(descriptor)
                } else {
                    emptyModuleSlot(size: 30)
                }
            }
            settingsButton(size: 30)
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.34))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
        }
    }

    /// The seven saved positions are the only normal compact navigation slots.
    /// Enabled but unpinned modules remain available from the module library.
    private var visibleModuleDescriptors: [IslandModuleDescriptor] {
        settings.islandModuleConfiguration.pinnedModuleIDs.compactMap {
            registry.descriptor(for: $0)
        }
    }

    private var pinnedModuleSlots: [IslandModuleDescriptor?] {
        let descriptors = visibleModuleDescriptors.map(Optional.some)
        return descriptors + Array(
            repeating: nil,
            count: max(0, IslandModuleConfiguration.maximumPinnedModules
                       - descriptors.count)
        )
    }

    private func floatingModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                }
                .contentShape(Circle())
                .opacity(isEnabled || isSelected ? 1 : 0.46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private func emptyModuleSlot(size: CGFloat) -> some View {
        IslandEmptyModuleSlot(size: size) { moduleID in
            coordinator.selectedModule = moduleID
        }
    }

    private func modulePage(_ module: IslandModuleID) -> some View {
        moduleContainer.contentView(
            for: module,
            context: IslandModuleViewContext(
                onPerformRecovery: onPerformRecovery,
                onOpenModule: { coordinator.selectedModule = $0 },
                onOpenSettings: openSettings
            )
        )
    }

    private var compactAccessibilityLabel: String {
        switch compactDisplay {
        case .battery:
            return String(localized: "Battery, \(powerMonitor.snapshot.percentage) percent")
        case .shelf:
            return String(localized: "OpenYoink Island, \(shelfStore.items.count) shelf items")
        case .timer:
            if case .finished = timerStore.state {
                return String(localized: "Timer finished")
            }
            return String(localized: "Timer, \(timerStore.compactRemaining) remaining")
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
        if let moduleID = compactDisplay.moduleID, registry.isEnabled(moduleID) {
            return moduleID
        }
        return defaultModuleDescriptor?.id ?? .transfers
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

/// Shared wing layout used by the physical-notch Island and its rendered layout tests.
struct IslandCompactWingRow<Leading: View, Trailing: View>: View {
    /// Center every leading symbol in the same 24-point slot, biased toward the notch.
    private static var leadingOuterInset: CGFloat { 13 }
    private static var leadingSlotWidth: CGFloat { 24 }

    let cameraHousingWidth: CGFloat
    let leading: Leading
    let trailing: Trailing

    init(cameraHousingWidth: CGFloat,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.cameraHousingWidth = cameraHousingWidth
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: Self.leadingSlotWidth, alignment: .center)
                .padding(.leading, Self.leadingOuterInset)
                .padding(.trailing, IslandGeometryResolver.compactWingWidth
                         - Self.leadingOuterInset - Self.leadingSlotWidth)
            Spacer()
                .frame(width: cameraHousingWidth)
            trailing
                .frame(width: IslandGeometryResolver.compactWingWidth - 10,
                       alignment: .center)
                .padding(.trailing, 10)
        }
    }
}

/// Shared by the live compact Island and its rendered preview tests.
struct IslandCompactAIValueText: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct IslandCompactBatteryValueText: View {
    let percentage: Int

    var body: some View {
        Text("\(percentage)%")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// All compact wing SF Symbols share this typography and centered canvas.
/// Color and animation belong to the caller; wing placement belongs to the row.
struct IslandCompactWingIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .imageScale(.medium)
            .frame(width: 22, height: 22, alignment: .center)
            .accessibilityHidden(true)
    }
}

struct IslandCompactTransferSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            IslandCompactWingIcon(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.white)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
        }
        .accessibilityHidden(true)
    }
}

private struct IslandEmptyModuleSlot: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry
    @State private var isPresentingPicker = false

    let size: CGFloat
    let onOpenModule: (IslandModuleID) -> Void

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size == 30 ? 10 : 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.075)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a module"))
        .help(Text("Choose a module"))
        .popover(isPresented: $isPresentingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a module")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(unpinnedModuleDescriptors) { descriptor in
                    Button {
                        settings.setIslandModuleEnabled(true, id: descriptor.id)
                        settings.setIslandModulePinned(true, id: descriptor.id)
                        onOpenModule(descriptor.id)
                        isPresentingPicker = false
                    } label: {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 190)
        }
    }

    private var unpinnedModuleDescriptors: [IslandModuleDescriptor] {
        registry.descriptors.filter {
            !settings.isIslandModulePinned($0.id)
        }
    }
}

/// Screen-attached surfaces use shallow inward top corners and fuller convex
/// bottom corners. The shape stays flush with the screen edge while avoiding
/// the square, pasted-on silhouette of a regular rounded rectangle.
private struct IslandSurfaceShape: InsettableShape {
    var attachedToScreenTop: Bool
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard attachedToScreenTop else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        let bottomRadius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topCut = min(7, max(4, bottomRadius * 0.45))
        let leftBody = rect.minX + topCut
        let rightBody = rect.maxX - topCut
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: leftBody, y: rect.minY + topCut),
            control1: CGPoint(x: rect.minX + topCut * 0.55, y: rect.minY),
            control2: CGPoint(x: leftBody, y: rect.minY + topCut * 0.45)
        )
        path.addLine(to: CGPoint(x: leftBody, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rightBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: rect.minY + topCut))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rightBody, y: rect.minY + topCut * 0.45),
            control2: CGPoint(x: rect.maxX - topCut * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}


struct IslandModuleLibraryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry

    let onOpenModule: (IslandModuleID) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: IslandModuleLayout.headerSpacing) {
            IslandModuleHeader(
                title: "Quick Settings",
                subtitle: String(localized: "Choose up to seven pinned modules"),
                systemImage: "square.grid.2x2"
            )

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(registry.descriptors) { descriptor in
                        moduleRow(descriptor)
                    }
                }
            }

            HStack {
                Text("Drag pinned rows to reorder the seven Island positions.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
                Spacer()
                Button("Open Full Settings") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moduleRow(_ descriptor: IslandModuleDescriptor) -> some View {
        let enabled = settings.isIslandModuleEnabled(descriptor.id)
        let pinned = settings.isIslandModulePinned(descriptor.id)
        let pinnedCount = settings.islandModuleConfiguration.pinnedModuleIDs.count

        return HStack(spacing: 10) {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.white.opacity(0.42))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(pinned
                     ? String(localized: "Pinned in the Island strip")
                     : enabled
                        ? String(localized: "Enabled in the module library")
                        : String(localized: "Disabled"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
            }

            Spacer(minLength: 4)

            if enabled {
                Button("Open") { onOpenModule(descriptor.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.weight(.semibold))
            }

            Button {
                settings.setIslandModulePinned(!pinned, id: descriptor.id)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || (!pinned && pinnedCount >= 5))
            .opacity(!enabled || (!pinned && pinnedCount >= 5) ? 0.34 : 1)
            .accessibilityLabel(Text(pinned ? "Unpin module" : "Pin module"))

            Toggle("", isOn: Binding(
                get: { settings.isIslandModuleEnabled(descriptor.id) },
                set: { settings.setIslandModuleEnabled($0, id: descriptor.id) }
            ))
            .labelsHidden()
            .toggleStyle(IslandClipboardToggleStyle())
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(pinned ? 0.085 : 0.045))
        }
        .draggable(pinned ? descriptor.id.rawValue : "")
        .dropDestination(for: String.self) { items, _ in
            guard pinned,
                  let sourceRawValue = items.first,
                  !sourceRawValue.isEmpty else { return false }
            let ids = settings.islandModuleConfiguration.pinnedModuleIDs
            let sourceID = IslandModuleID(rawValue: sourceRawValue)
            guard let source = ids.firstIndex(of: sourceID),
                  let destination = ids.firstIndex(of: descriptor.id),
                  source != destination else { return false }
            settings.movePinnedIslandModules(
                fromOffsets: IndexSet(integer: source),
                toOffset: destination > source ? destination + 1 : destination
            )
            return true
        }
    }
}





private struct IslandSurfaceRevealModifier: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var opacity: Double
    let collapsedWidth: CGFloat
    let collapsedHeight: CGFloat
    let attachedToScreenTop: Bool

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, opacity) }
        set {
            progress = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let clampedProgress = min(max(progress, 0), 1)
                    let minimumWidth = min(collapsedWidth, proxy.size.width)
                    let minimumHeight = min(collapsedHeight, proxy.size.height)
                    let revealedWidth = minimumWidth
                        + (proxy.size.width - minimumWidth) * clampedProgress
                    let revealedHeight = minimumHeight
                        + (proxy.size.height - minimumHeight) * clampedProgress
                    IslandSurfaceShape(
                        attachedToScreenTop: attachedToScreenTop,
                        cornerRadius: 26
                    )
                    .fill(Color.white)
                    .frame(width: revealedWidth, height: revealedHeight,
                           alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                }
            }
            .opacity(opacity)
    }
}
