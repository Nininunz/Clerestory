import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandExpandedView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DropTargetState.self) private var dropTargetState
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(IslandModuleContainer.self) private var moduleContainer
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(FavoriteFolderDropCoordinator.self) private var folderCopy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        IslandSurfaceAnimationHost(
            isExpanded: coordinator.surfaceState.isExpanded,
            transitionID: coordinator.surfaceTransitionID,
            onCompleted: coordinator.completeSurfaceTransition
        ) { reveal in
            GeometryReader { surface in
                expandedContent(reveal: reveal)
                    .environment(\.islandSurfaceHeight, surface.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: coordinator.currentLayout?.expandedFrame.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay {
                IslandDropOutline(
                    progress: reveal.progress,
                    collapsedSize: reveal.collapsedSize,
                    attachedToScreenTop: false,
                    state: dropTargetState
                )
                .opacity(reveal.opacity)
            }
        }
        .padding(IslandSurfaceShadow.inset)
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
        .onChange(of: settings.effectiveIslandModuleConfiguration, initial: true) {
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
        .onChange(of: coordinator.selectedModule) {
            if !registry.isEnabled(coordinator.selectedModule) {
                coordinator.selectedModule = registry.enabledDescriptors.first?.id ?? .quickSettings
            }
            samplingContextChanged()
        }
        .onChange(of: coordinator.surfaceState) { samplingContextChanged() }
    }

    private func samplingContextChanged() {
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        if coordinator.surfaceState.isExpanded, coordinator.selectedModule == .media {
            nowPlayingStore.refresh()
        }
    }

    private func expandedContent(reveal: IslandSurfaceReveal) -> some View {
        IslandExpandedSurface(reveal: reveal, showsShadow: true) {
            expandedToolbar
                .padding(.top, 12)
                .padding(.horizontal, 14)
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

    private var expandedToolbar: some View {
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
                    moduleShortcutButton(descriptor)
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
        settings.effectiveIslandShortcuts.pinnedModuleIDs.compactMap {
            registry.descriptor(for: $0)
        }
    }

    private var pinnedModuleSlots: [IslandModuleDescriptor?] {
        settings.effectiveIslandShortcuts.shortcutPositions.map { id in
            id.flatMap { registry.descriptor(for: $0) }
        }
    }

    private var shortcutIndices: [Int] {
        settings.effectiveIslandShortcuts
            .visibleShortcutIndices()
    }

    private func moduleShortcutButton(
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
                        settings.assignIslandShortcut(descriptor.id, at: position)
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
            settings.isIslandModuleAvailable($0.id) && !settings.islandModuleConfiguration.isPinned($0.id)
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
                Button { settings.restoreDefaultIslandShortcuts() } label: {
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
            Text(positionLabel(index))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90,
                       alignment: .leading)
            Picker(positionLabel(index), selection: Binding<IslandModuleID?>(
                get: { settings.effectiveIslandShortcuts.shortcutPositions[index] },
                set: { settings.assignIslandShortcut($0, at: index) }
            )) {
                Text("Empty").tag(nil as IslandModuleID?)
                    .disabled(settings.effectiveIslandShortcuts.shortcutPositions[index] == .quickSettings)
                Label("Quick Settings", systemImage: "square.grid.2x2")
                    .tag(Optional(IslandModuleID.quickSettings))
                ForEach(registry.enabledDescriptors) { descriptor in
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                        .tag(Optional(descriptor.id))
                        .disabled(settings.effectiveIslandShortcuts.shortcutPositions[index] == .quickSettings
                                  && !settings.islandModuleConfiguration.isPinned(descriptor.id))
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
        String(localized: "Position \((shortcutIndices.firstIndex(of: index) ?? 0) + 1)")
    }

    private var shortcutIndices: [Int] {
        return settings.effectiveIslandShortcuts
            .visibleShortcutIndices()
    }
}

private struct CompactRowFramesKey: PreferenceKey {
    static let defaultValue: [IslandModuleID: CGRect] = [:]
    static func reduce(value: inout [IslandModuleID: CGRect], nextValue: () -> [IslandModuleID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
