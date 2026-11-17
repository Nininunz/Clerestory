import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfPresentationRootView: View {
    let presentationStyle: ShelfPresentationStyle
    var compactOnly = false
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if presentationStyle == .island {
                IslandRootView(
                    compactOnly: compactOnly,
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
    var compactOnly = false
    @Environment(SettingsStore.self) private var settings
    @Environment(ShelfStore.self) private var shelfStore
    @Environment(DropTargetState.self) private var dropTargetState
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
    @State private var isCollapseControlHovering = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var compactArtworkImage: NSImage?
    @State private var dropOutlineProgress: CGFloat = 0
    @State private var renderedSurfaceState: IslandSurfaceState = .compact
    @State private var activeSurfaceAnimation: UUID?
    @State private var requestedSurfaceTransitionID: UInt64 = 0

    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            if compactOnly {
                compactContent
            } else if renderedSurfaceState.isExpanded {
                GeometryReader { surface in
                    expandedContent
                        .environment(\.islandSurfaceHeight, surface.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                    .frame(width: coordinator.currentLayout?.expandedFrame.width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0.82,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: expandedUsesNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: expandedUsesNotch
                            )
                        ),
                        removal: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: expandedUsesNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: expandedUsesNotch
                            )
                        )
                    ))
            } else if !hasSeparateExpandedPanel {
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
        .overlay {
            if !compactOnly {
                IslandDropOutline(
                    progress: dropOutlineProgress,
                    collapsedSize: CGSize(width: collapsedSurfaceWidth, height: collapsedSurfaceHeight),
                    attachedToScreenTop: expandedUsesNotch,
                    state: dropTargetState
                )
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(compactOnly ? "island.compact" : "island.root")
        .alert("File Already Exists", isPresented: Binding(
            get: { !compactOnly && folderCopy.conflictName != nil },
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
        .onChange(of: settings.effectiveIslandModuleConfiguration, initial: true) {
            guard !compactOnly else { return }
            registry.apply(settings: settings)
            moduleContainer.apply(
                configuration: settings.effectiveIslandModuleConfiguration,
                isActive: settings.islandEnabled
            )
            if !registry.isEnabled(coordinator.selectedModule) {
                coordinator.selectedModule = visibleModuleDescriptors.first?.id
                    ?? registry.enabledDescriptors.first?.id ?? .quickSettings
            }
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            compactArtworkImage = data.flatMap(NSImage.init(data:))
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
        .onChange(of: coordinator.selectedModule) {
            guard !compactOnly else { return }
            if !registry.isEnabled(coordinator.selectedModule) {
                coordinator.selectedModule = registry.enabledDescriptors.first?.id ?? .quickSettings
            }
            samplingContextChanged()
        }
        .onChange(of: coordinator.surfaceState) { samplingContextChanged() }
    }

    private func renderSurface(_ state: IslandSurfaceState) {
        // Only the expanded host owns transition completion and window collapse.
        guard !compactOnly else { return }
        requestedSurfaceTransitionID = coordinator.surfaceTransitionID
        if reduceMotion {
            activeSurfaceAnimation = nil
            renderedSurfaceState = state
            dropOutlineProgress = state.isExpanded ? 1 : 0
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
            dropOutlineProgress = state.isExpanded ? 1 : 0
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
        guard !compactOnly else { return }
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        if coordinator.surfaceState.isExpanded, coordinator.selectedModule == .media {
            nowPlayingStore.refresh()
        }
    }

    private var collapsedSurfaceHeight: CGFloat {
        if hasSeparateExpandedPanel { return IslandGeometryResolver.floatingCompactSize.height }
        return coordinator.currentLayout?.compactFrame.height
            ?? IslandGeometryResolver.floatingCompactSize.height
    }

    private var collapsedSurfaceWidth: CGFloat {
        if hasSeparateExpandedPanel { return IslandGeometryResolver.floatingCompactSize.width }
        return coordinator.currentLayout?.compactFrame.width
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
        IslandExpandedSurface(hasPhysicalNotch: expandedUsesNotch) {
            if expandedUsesNotch {
                physicalNotchModuleStrip
            } else {
                floatingIslandToolbar
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
            }
        } content: {
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
        }
        // The detached panel on notched displays uses AppKit's window shadow.
        // The existing notchless presentation still draws its shadow here.
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

    private var hasSeparateExpandedPanel: Bool {
        coordinator.currentLayout?.hasSeparateExpandedPanel == true
    }

    private var expandedUsesNotch: Bool {
        coordinator.currentLayout?.expandedUsesNotch == true
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
        let leadingIndices = shortcutIndices.filter { $0 < IslandModuleConfiguration.shortcutSlotsPerSide }
        let trailingIndices = shortcutIndices.filter { $0 >= IslandModuleConfiguration.shortcutSlotsPerSide }
        let notchWidth = coordinator.currentLayout?.cameraHousingWidth ?? 0
        let notchHeight = coordinator.currentLayout?.topInset ?? 32
        let stripHeight = notchHeight
            + IslandGeometryResolver.physicalNotchClickExtension

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(leadingIndices, id: \.self) { index in
                        if let descriptor = slots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24, position: index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Color.clear
                    .frame(width: notchWidth)
                    .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(trailingIndices, id: \.self) { index in
                        if let descriptor = slots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24, position: index)
                        }
                    }
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
            ForEach(shortcutIndices, id: \.self) { index in
                if let descriptor = pinnedModuleSlots[index] {
                    floatingModuleButton(descriptor)
                } else {
                    emptyModuleSlot(size: 30, position: index)
                }
            }
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

    /// Saved positions provide expanded navigation shortcuts.
    /// Enabled but unpinned modules remain available from the module library.
    private var visibleModuleDescriptors: [IslandModuleDescriptor] {
        settings.effectiveIslandShortcuts(hasPhysicalNotch: expandedUsesNotch).pinnedModuleIDs.compactMap {
            registry.descriptor(for: $0)
        }
    }

    private var pinnedModuleSlots: [IslandModuleDescriptor?] {
        settings.effectiveIslandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).shortcutPositions.map { id in
            id.flatMap { registry.descriptor(for: $0) }
        }
    }

    private var shortcutIndices: [Int] {
        settings.effectiveIslandShortcuts(hasPhysicalNotch: expandedUsesNotch)
            .visibleShortcutIndices(hasPhysicalNotch: expandedUsesNotch)
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

    private func emptyModuleSlot(size: CGFloat, position: Int) -> some View {
        IslandEmptyModuleSlot(size: size, position: position) { moduleID in
            coordinator.selectedModule = moduleID
        }
    }

    private func modulePage(_ module: IslandModuleID) -> some View {
        let module = registry.isEnabled(module) ? module : .quickSettings
        return IslandModuleHost(descriptor: moduleContainer.registration(for: module)?.descriptor,
                         coordinator: coordinator) {
            moduleContainer.contentView(
                for: module,
                context: IslandModuleViewContext(
                    onPerformRecovery: onPerformRecovery,
                    onOpenModule: { if registry.isEnabled($0) { coordinator.selectedModule = $0 } },
                    onOpenSettings: openSettings
                )
            )
        }
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

/// Shared wing layout used by the physical-notch Island and its rendered layout tests.
struct IslandCompactWingRow<Leading: View, Trailing: View>: View {
    /// Center every leading symbol in the same 24-point slot, biased toward the notch.
    private static var leadingOuterInset: CGFloat { 13 }
    private static var leadingSlotWidth: CGFloat { 24 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cameraHousingWidth: CGFloat
    let display: IslandCompactDisplay?
    let isBackwards: () -> Bool
    let height: CGFloat?
    let leading: Leading
    let trailing: Trailing

    init(cameraHousingWidth: CGFloat,
         display: IslandCompactDisplay? = nil,
         isBackwards: @escaping () -> Bool = { false },
         height: CGFloat? = nil,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.cameraHousingWidth = cameraHousingWidth
        self.display = display
        self.isBackwards = isBackwards
        self.height = height
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            slidingWing {
                leading
                    .frame(width: Self.leadingSlotWidth, alignment: .center)
                    .padding(.leading, Self.leadingOuterInset)
                    .padding(.trailing, IslandGeometryResolver.compactWingWidth
                             - Self.leadingOuterInset - Self.leadingSlotWidth)
            }
            Spacer()
                .frame(width: cameraHousingWidth)
            slidingWing {
                trailing
                    .frame(width: IslandGeometryResolver.compactWingWidth - 10,
                           alignment: .center)
                    .padding(.trailing, 10)
            }
        }
        .compositingGroup()
        .clipShape(IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11))
    }

    @ViewBuilder
    private func slidingWing<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let display {
            ZStack {
                content()
                    .id(display)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(
                            active: IslandCompactSlideModifier(progress: 1, isBackwards: isBackwards),
                            identity: IslandCompactSlideModifier(progress: 0, isBackwards: isBackwards)),
                        removal: .modifier(
                            active: IslandCompactSlideModifier(progress: -1, isBackwards: isBackwards),
                            identity: IslandCompactSlideModifier(progress: 0, isBackwards: isBackwards))
                    ))
            }
            .frame(width: IslandGeometryResolver.compactWingWidth, height: height)
            // Clip each wing independently so outgoing content never crosses the camera.
            .clipped()
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.24), value: display)
        } else {
            content()
        }
    }
}

/// Resolve direction live, including for a departing view created by an earlier cycle.
/// Only progress interpolates; changing direction must not animate through the old sign.
struct IslandCompactSlideModifier: AnimatableModifier {
    nonisolated var progress: CGFloat
    let isBackwards: () -> Bool

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var horizontalOffset: CGFloat {
        progress * IslandGeometryResolver.compactWingWidth * (isBackwards() ? -1 : 1)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: horizontalOffset)
            .opacity(1 - abs(progress))
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
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @State private var isPresentingPicker = false

    let size: CGFloat
    let position: Int
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
                        settings.assignIslandShortcut(descriptor.id, at: position, hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true)
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
            settings.isIslandModuleAvailable($0.id) && !settings.islandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).isPinned($0.id)
        }
    }
}

/// Screen-attached surfaces use shallow inward top corners and fuller convex
/// bottom corners. The shape stays flush with the screen edge while avoiding
/// the square, pasted-on silhouette of a regular rounded rectangle.


struct IslandModuleLibraryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draggedCompactModule: IslandModuleID?
    @State private var compactDragOrder: [IslandModuleID]?
    @State private var compactDragTarget: IslandModuleID?
    @State private var hoveredCompactHandle: IslandModuleID?
    @State private var compactRowFrames: [IslandModuleID: CGRect] = [:]
    @GestureState private var compactDragActive = false
    @Namespace private var shortcutSwitcher
    @Namespace private var compactRowMotion
    private var showsCompact: Bool {
        get { coordinator.quickSettingsShowsCompact }
        nonmutating set { coordinator.quickSettingsShowsCompact = newValue }
    }

    let onOpenSettings: () -> Void


    var body: some View {
        VStack(spacing: IslandModuleLayout.headerSpacing) {
            IslandModuleHeader(
                title: "Quick Settings",
                subtitle: showsCompact ? String(localized: "Choose compact modules and their cycling order")
                    : String(localized: "Choose shortcuts and arrange their positions"),
                systemImage: "square.grid.2x2",
                showsExtendButton: false
            ) {
                pageSwitcher
            }
            IslandModuleScrollView {
                // Both pages contribute their natural height, while only the selected
                // page is visible or interactive. Extension therefore fits the taller
                // page before the user has visited it, with no resize on switching.
                ZStack(alignment: .topLeading) {
                    expandedEditor
                        .opacity(showsCompact ? 0 : 1)
                        .allowsHitTesting(!showsCompact)
                        .disabled(showsCompact)
                        .accessibilityHidden(showsCompact)
                    compactEditor
                        .opacity(showsCompact ? 1 : 0)
                        .allowsHitTesting(showsCompact)
                        .disabled(!showsCompact)
                        .accessibilityHidden(!showsCompact)
                }
            }
            IslandModuleFooter {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IslandHeaderButtonStyle())
                .help("Settings")
                .accessibilityLabel(Text("Settings"))
                Spacer()
                IslandModuleExtendButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: compactDragActive) { _, active in
            if !active { clearCompactDrag() }
        }
        .onDisappear {
            hoveredCompactHandle = nil
            clearCompactDrag()
        }
    }

    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(shortcutIndices, id: \.self) { index in
                positionRow(index)
            }
            HStack {
                Label("One position must contain Quick Settings", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { settings.restoreDefaultIslandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true) } label: {
                    Text("Restore Defaults")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                    .buttonStyle(IslandPressFeedbackStyle())
                    .help("Restore shortcut positions without changing enabled modules")
            }
            .padding(.vertical, 4)
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { compact in
                Button {
                    clearCompactDrag()
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { showsCompact = compact }
                } label: {
                    Image(systemName: compact ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 27, height: 24)
                        .foregroundStyle(showsCompact == compact ? .white : IslandVisualStyle.tertiaryText)
                        .background {
                            if showsCompact == compact {
                                Capsule().fill(Color.white.opacity(0.11))
                                    .matchedGeometryEffect(id: "selection", in: shortcutSwitcher)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(IslandPressFeedbackStyle(cornerRadius: 12))
                .help(compact ? "Compact" : "Expanded")
                .accessibilityLabel(Text(compact ? "Compact shortcuts" : "Expanded shortcuts"))
                .modifier(IslandSelectedAccessibilityModifier(selected: showsCompact == compact))
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(IslandVisualStyle.hairline, lineWidth: 1) }
    }

    private var compactEditor: some View {
        let order = (compactDragOrder ?? settings.compactModuleOrder).filter { settings.isIslandModuleAvailable($0) }
        let rows = order + IslandCompactDisplay.cycleOrder.filter { settings.isIslandModuleAvailable($0) && !order.contains($0) }
        return VStack(spacing: 7) {
            ForEach(rows, id: \.self) { id in
                if !order.isEmpty, id == rows.dropFirst(order.count).first {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .accessibilityHidden(true)
                }
                if let descriptor = registry.descriptor(for: id) {
                    compactRow(descriptor)
                        .matchedGeometryEffect(id: descriptor.id, in: compactRowMotion, properties: .position)
                }
            }
            HStack {
                Label("Drag included modules or use arrows to set cycling order.", systemImage: "arrow.up.arrow.down")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { settings.compactModuleOrder = IslandCompactDisplay.cycleOrder } label: {
                    Text("Restore Defaults")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                    .buttonStyle(IslandPressFeedbackStyle())
            }
        }
        .coordinateSpace(name: "compactOrder")
        .onPreferenceChange(CompactRowFramesKey.self) { compactRowFrames = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: order)
    }

    private func compactRow(_ descriptor: IslandModuleDescriptor) -> some View {
        let order = (compactDragOrder ?? settings.compactModuleOrder).filter { settings.isIslandModuleAvailable($0) }
        let index = order.firstIndex(of: descriptor.id)
        let row = HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: descriptor.systemImage).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title).font(.system(size: 12, weight: .medium))
                    if !settings.isIslandModuleEnabled(descriptor.id) {
                        Text("Disabled in Modules").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(compactReorderGesture(descriptor.id), including: index != nil ? .all : .none)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if index != nil { hoveredCompactHandle = descriptor.id }
                case .ended:
                    if hoveredCompactHandle == descriptor.id { hoveredCompactHandle = nil }
                }
                updateCompactDragCursor()
            }
            Spacer(minLength: 4)
            if let index {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        settings.moveCompactModule(descriptor.id, to: order[index - 1])
                    }
                } label: { Image(systemName: "arrow.up").frame(width: 24, height: 24) }
                .disabled(index == 0)
                .accessibilityLabel(Text("Move earlier"))
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        settings.moveCompactModule(descriptor.id, to: order[index + 1])
                    }
                } label: { Image(systemName: "arrow.down").frame(width: 24, height: 24) }
                .disabled(index == order.count - 1)
                .accessibilityLabel(Text("Move later"))
            }
            Toggle(descriptor.title, isOn: Binding(
                get: { settings.compactModuleOrder.contains(descriptor.id) },
                set: { settings.setCompactModuleIncluded($0, id: descriptor.id) }
            ))
            .labelsHidden()
            .toggleStyle(IslandClipboardToggleStyle(showsLabel: false))
        }
        .buttonStyle(IslandPressFeedbackStyle())
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
        return row
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CompactRowFramesKey.self,
                        value: [descriptor.id: geometry.frame(in: .named("compactOrder"))])
                }
            }
            .opacity(draggedCompactModule == descriptor.id ? 0.65 : 1)
    }

    private func compactReorderGesture(_ id: IslandModuleID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("compactOrder"))
            .updating($compactDragActive) { _, active, _ in active = true }
            .onChanged { value in
                if draggedCompactModule == nil {
                    compactDragOrder = settings.compactModuleOrder
                    draggedCompactModule = id
                }
                NSCursor.closedHand.set()
                if compactRowFrames[id]?.contains(value.location) == true {
                    compactDragTarget = nil
                    return
                }
                guard var order = compactDragOrder,
                      let target = order.first(where: { $0 != id && compactRowFrames[$0]?.contains(value.location) == true }),
                      compactDragTarget != target,
                      let source = order.firstIndex(of: id),
                      let destination = order.firstIndex(of: target) else { return }
                compactDragTarget = target
                order.remove(at: source)
                order.insert(id, at: destination)
                compactDragOrder = order
            }
            .onEnded { value in
                if let order = compactDragOrder,
                   order.contains(where: { compactRowFrames[$0]?.contains(value.location) == true }) {
                    settings.compactModuleOrder = order
                }
                clearCompactDrag()
            }
    }

    private func clearCompactDrag() {
        draggedCompactModule = nil
        compactDragOrder = nil
        compactDragTarget = nil
        updateCompactDragCursor()
    }

    private func updateCompactDragCursor() {
        if draggedCompactModule != nil {
            NSCursor.closedHand.set()
        } else if hoveredCompactHandle != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func positionRow(_ index: Int) -> some View {
        HStack(spacing: 12) {
            if coordinator.currentLayout?.expandedUsesNotch == true {
                Text("\((shortcutIndices.firstIndex(of: index) ?? 0) + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Text(positionLabel(index))
                .font(.system(size: 12, weight: .medium))
                .frame(width: coordinator.currentLayout?.expandedUsesNotch == true ? 58 : 90,
                       alignment: .leading)
            Picker(positionLabel(index), selection: Binding<IslandModuleID?>(
                get: { settings.effectiveIslandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).shortcutPositions[index] },
                set: { settings.assignIslandShortcut($0, at: index, hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true) }
            )) {
                Text("Empty").tag(nil as IslandModuleID?)
                    .disabled(settings.effectiveIslandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).shortcutPositions[index] == .quickSettings)
                Label("Quick Settings", systemImage: "square.grid.2x2")
                    .tag(Optional(IslandModuleID.quickSettings))
                ForEach(registry.enabledDescriptors) { descriptor in
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                        .tag(Optional(descriptor.id))
                        .disabled(settings.effectiveIslandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).shortcutPositions[index] == .quickSettings
                                  && !settings.islandShortcuts(hasPhysicalNotch: coordinator.currentLayout?.expandedUsesNotch == true).isPinned(descriptor.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("island.shortcut.position.\(index)")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        }
    }

    private func positionLabel(_ index: Int) -> String {
        guard coordinator.currentLayout?.expandedUsesNotch == true else {
            return String(localized: "Position \((shortcutIndices.firstIndex(of: index) ?? 0) + 1)")
        }
        let perSide = IslandModuleConfiguration.shortcutSlotsPerSide
        let sideIndices = shortcutIndices.filter { ($0 < perSide) == (index < perSide) }
        let number = (sideIndices.firstIndex(of: index) ?? 0) + 1
        return index < perSide
            ? String(localized: "Left \(number)")
            : String(localized: "Right \(number)")
    }

    private var shortcutIndices: [Int] {
        let notched = coordinator.currentLayout?.expandedUsesNotch == true
        return settings.effectiveIslandShortcuts(hasPhysicalNotch: notched)
            .visibleShortcutIndices(hasPhysicalNotch: notched)
    }
}

private struct CompactRowFramesKey: PreferenceKey {
    static let defaultValue: [IslandModuleID: CGRect] = [:]
    static func reduce(value: inout [IslandModuleID: CGRect], nextValue: () -> [IslandModuleID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
