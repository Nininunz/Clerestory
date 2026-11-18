import AppKit
import SwiftUI

enum ShelfPresentationStyle: Sendable, Equatable {
    case classic
    case island
}

private struct ShelfPresentationStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue: ShelfPresentationStyle = .classic
}

private struct ShelfSelectionModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ShelfFocusActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

private struct ShelfUserRemovalActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor (@MainActor () -> Void) -> Void)? { nil }
}

extension EnvironmentValues {
    var shelfUserRemovalAction: (@MainActor (@MainActor () -> Void) -> Void)? {
        get { self[ShelfUserRemovalActionEnvironmentKey.self] }
        set { self[ShelfUserRemovalActionEnvironmentKey.self] = newValue }
    }
    var shelfFocusAction: (@MainActor () -> Void)? {
        get { self[ShelfFocusActionEnvironmentKey.self] }
        set { self[ShelfFocusActionEnvironmentKey.self] = newValue }
    }
    var shelfSelectionMode: Bool {
        get { self[ShelfSelectionModeEnvironmentKey.self] }
        set { self[ShelfSelectionModeEnvironmentKey.self] = newValue }
    }
    var shelfPresentationStyle: ShelfPresentationStyle {
        get { self[ShelfPresentationStyleEnvironmentKey.self] }
        set { self[ShelfPresentationStyleEnvironmentKey.self] = newValue }
    }
}

private struct ShelfIconButtonStyle: ButtonStyle {
    var active = false
    var expanded = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        HoverContent(configuration: configuration, active: active,
                     expanded: expanded, destructive: destructive)
    }

    private struct HoverContent: View {
        let configuration: Configuration
        let active: Bool
        let expanded: Bool
        let destructive: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(foregroundColor)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.14) :
                              expanded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(isEnabled && configuration.isPressed ? 0.16 :
                                                           isEnabled && isHovering ? 0.09 : 0))
                        }
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovering)
        }

        private var foregroundColor: Color {
            guard isEnabled else { return Color.primary.opacity(0.25) }
            if active { return .accentColor }
            if destructive && (isHovering || configuration.isPressed) { return .red }
            return Color.primary.opacity(isHovering ? 0.95 : 0.72)
        }
    }
}

/// Shelf root view (S3: real content rendering).
///
/// Visual guidelines (implementation plan §3): vibrancy bottom (.hudWindow material) + 16pt corner radius
/// + 1pt inner stroke (white 8%); equal width grid (column width ~88pt, spacing 12pt) with vertical
/// scrolling; top minimal title bar (name + item count); show `ShelfEmptyState` when empty. Projection is
/// still handled by the window layer (`ShelfPanel.hasShadow`), no redraw here.
///
/// Interactions: single tap for single selection, ⌘ tap to toggle multiple selection, click on empty area
/// to clear selection and collapse Stack; click on Stack card to expand overlay (only one expanded at a
/// time), click outside or tap again to collapse.
///
/// S4: The two reserved states `isDropTargeted` / `dropInsertionIndex` have been consolidated into
/// `@Environment(DropTargetState.self)` (DragContainerView drives the highlight and insertion indicator
/// line); the card insertion animation modifier (spring, response 0.35, damping 0.7) is in place. C6: Card
/// frame is reported via `ShelfGridGeometry` (window .global coordinates), DragContainerView maps the
/// mouse position to row/column insertion index. D10: Inline prompt for failed drag-in/materialization
/// (`ShelfNoticeModel`) is rendered below the title bar.
struct ShelfView: View {
    let presentationStyle: ShelfPresentationStyle

    init(presentationStyle: ShelfPresentationStyle = .classic) {
        self.presentationStyle = presentationStyle
    }

    @Environment(ShelfStore.self) private var store

    /// S4: Drag-in hover highlight and insertion indicator line position is driven by DragContainerView
    /// (NSDraggingDestination bridging).
    @Environment(DropTargetState.self) private var dropTargetState
    /// S9: Custom position mode determination + frame persistence after dragging ends (customShelfFrame).
    @Environment(SettingsStore.self) private var settings
    /// S6: Quick Look session; synchronize open preview when selection changes (nil is no-op).
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    @Environment(\.bookmarkService) private var bookmarkService
    /// C5/C6: Card grid geometry (frame reporting + selection hit + drag-in insertion positioning shared).
    @Environment(ShelfGridGeometry.self) private var gridGeometry
    /// D10: Inline prompt for failed drag-in/materialization.
    @Environment(ShelfNoticeModel.self) private var notices
    @Environment(\.shelfRevealState) private var reveal
    /// v1.2: runtime-only asynchronous batch status.
    @Environment(TransferStore.self) private var transferStore
    @Environment(ShelfInteractionState.self) private var interaction
    @Environment(\.accessibilityAnnouncementCenter) private var announcementCenter
    /// v1.2: unavailable-item actions (external reconnect vs managed recovery).
    @Environment(\.itemRecoveryController) private var itemRecoveryController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    /// Task three: The action of folding the edge handle (ShelfWindowController injection; Preview is nil
    /// no-op).
    @Environment(\.shelfHideAction) private var shelfHideAction
    @Environment(\.shelfFocusAction) private var shelfFocusAction
    @Environment(\.shelfUserRemovalAction) private var shelfUserRemovalAction
    @State private var showsManagementActions = false
    @State private var duplicateHighlightIDs: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    /// Card insertion/waymaking animation (§3: spring, response 0.35, damping 0.7).
    static let cardAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let cornerRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    /// Grid column width baseline (adjusted to narrow when handle folds to 84: handle 10pt + 2pt gap no
    /// longer overlaps with first column card; `ShelfLayoutEngine.gridColumnMinimum` synchronized).
    static let columnWidth: CGFloat = 84

    var body: some View {
        presentedSurface
            .environment(\.shelfSelectionMode, interaction.isSelecting)
            .environment(\.colorScheme, presentationStyle == .classic
                         ? (settings.appearance.theme.colorScheme ?? systemColorScheme) : .dark)
            .environment(\.shelfPresentationStyle, presentationStyle)
            .onChange(of: store.items) {
                dropTargetState.reset()
                interaction.normalize(for: store.visibleItems)
                if store.items.isEmpty { interaction.isSelecting = false }
            }
            .task(id: store.duplicateDrop?.id) {
                duplicateHighlightIDs = []
                guard let drop = store.duplicateDrop,
                      Date().timeIntervalSince(drop.occurredAt) < 1.5 else { return }
                duplicateHighlightIDs = drop.cardIDs
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    duplicateHighlightIDs = []
                }
            }
            .onDisappear { showsManagementActions = false }
            .onChange(of: store.searchQuery) { normalizeSearch() }
            .onChange(of: store.contentFilter) { normalizeSearch() }
            .onChange(of: transferStore.currentTask, initial: true) { _, task in
                announcementCenter?.announce(task: task)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shelf.root")
    }

    @ViewBuilder
    private var presentedSurface: some View {
        if presentationStyle == .classic {
            ShelfInteractiveGlassSurface(appearance: settings.appearance,
                                         onBackgroundTap: clearSelectionAndCollapse) {
                Color.clear
                    .overlay { content }
                    .overlay { dropTargetHighlight }
                    .overlay { expandedStackOverlay }
                    .overlay(alignment: .bottom) { dropModeHint }
            }
            .animation(reduceMotion ? nil : Self.cardAnimation,
                       value: interaction.expandedStackID)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: notices.message != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: transferStore.hasVisibleActivity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: dropTargetState.mode)
            .padding(8)
            // The invisible fold handle area is attached after padding (in window content coordinate
            // system): the original position of the handle is 14pt from the panel edge —— attaching before
            // padding would be inset by 8pt, causing misalignment (real device click misses), must be
            // attached to the actual panel edge.
            .overlay(alignment: outerCollapseStripAlignment == .trailing ? .topTrailing : .topLeading) {
                outerCollapseStrip
            }
        } else {
            Color.clear
                .overlay { content }
                .overlay { expandedStackOverlay }
                .overlay(alignment: .bottom) { dropModeHint }
                .animation(reduceMotion ? nil : Self.cardAnimation,
                           value: interaction.expandedStackID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: notices.message != nil)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: transferStore.hasVisibleActivity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: dropTargetState.mode)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 4) {
            if presentationStyle == .classic {
                header
            }
            searchControls
            // No transfer strip while a shelf drag is in flight: inserting it
            // re-lays out the grid and clears card geometry mid-reorder, which
            // makes the insertion line fall back to "append to the end".
            if transferStore.hasVisibleActivity, transferStore.dragSessionsInFlight == 0 {
                ShelfActivityStrip(onPerformRecovery: performRecovery)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
            }
            resultsViewport
                .blur(radius: showsDuplicateDropOverlay ? 6 : 0)
                .clipped()
                .overlay { duplicateDropOverlay }
                .overlay(alignment: .bottom) {
                    if presentationStyle == .classic { noticeBanner }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                           value: showsDuplicateDropOverlay)
            if presentationStyle == .island {
                shelfFooter
                    .padding(.top, IslandModuleLayout.headerSpacing - 4)
            } else if shouldShowTopLevelQuickActions {
                ShelfQuickActionBar(items: topLevelActionItems)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(presentationStyle == .classic ? 8 : 0)
        .background {
            // Clicking the blank area clears the selection and collapses the Stack; card clicks are
            // handled by the card's own event layer. Classic mode is now handled by the glass surface hit
            // layer (geometry does not follow the height spring animation).
            if presentationStyle != .classic {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearSelectionAndCollapse)
            }
        }
    }

    @ViewBuilder
    private var resultsViewport: some View {
        if presentationStyle == .island {
            // Keep the search bar and footer in place when the grid becomes a message.
            Color.clear.overlay { results }
        } else {
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        if store.items.isEmpty {
            Group {
                if presentationStyle == .island {
                    IslandEmptyState(title: "Drop files here",
                                     message: "Hold ⌘ while dropping to move the original here",
                                     systemImage: "tray.and.arrow.down")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("shelf.emptyState")
                } else {
                    ShelfEmptyState()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
        } else if store.visibleItems.isEmpty {
            Group {
                if presentationStyle == .island {
                    IslandModuleState(title: "No Results", message: "Try a different search or filter.",
                                      systemImage: "magnifyingglass") {
                        Button("Clear Search and Filters") {
                            store.searchQuery = ""
                            store.contentFilter = .all
                        }
                    }
                } else {
                    Text("No Results").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
        } else {
            itemGrid
        }
    }

    private var showsDuplicateDropOverlay: Bool {
        ShelfDuplicateFeedback.usesFileOverlay && presentationStyle == .island
            && ShelfDuplicateFeedback.isDuplicateTarget(dropTargetState)
    }

    @ViewBuilder
    private var duplicateDropOverlay: some View {
        if showsDuplicateDropOverlay {
            Color.black.opacity(0.25)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.red)
                        Text("Already on Shelf")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Existing files will be skipped. New files will still be added.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .padding(16)
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("shelf.duplicateDrop")
                .transition(.opacity)
        }
    }

    /// Top minimal title bar: shelf name + item count (displays 'Selected/Total' when multiple items are
    /// selected). S9: in custom position mode, the entire title bar covers the WindowDragHandle (drag
    /// handle), with a grip symbol added before the title to indicate drag capability; the final frame
    /// after dragging is persisted to customShelfFrame.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if isCustomPosition {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Drag to move"))
            }
            // Left edge alignment: buttons are placed before the title (on the side of the screen), with
            // the arrow and position aligned in the same direction.
            if collapseHandleSide == .trailing {
                collapseButton(side: .trailing)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            Text("Shelf")
                .font(.headline)
            Spacer()
            Text(countCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if collapseHandleSide == .leading {
                collapseButton(side: .leading)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .overlay {
            if isCustomPosition {
                WindowDragHandle { frame in
                    settings.customShelfFrame = frame
                }
            }
        }
    }

    private var isCustomPosition: Bool {
        settings.shelfPosition == .custom
    }

    private var searchControls: some View {
        @Bindable var store = store
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                .keyboardShortcut("f", modifiers: .command)
                .help(Text("Search Shelf")).accessibilityLabel("Search Shelf")
                TextField("Search Shelf", text: $store.searchQuery)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("shelf.search")
                    .onKeyPress(.escape) { store.searchQuery = ""; searchFocused = false; return .handled }
                Button { store.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                }
                .help(Text("Clear Search"))
                .accessibilityLabel("Clear Search")
                .opacity(store.searchQuery.isEmpty ? 0 : 1)
                .disabled(store.searchQuery.isEmpty)
                .accessibilityHidden(store.searchQuery.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // issue #10: a soft capsule that sits *in* the glass instead of a
            // flat grey slab on top of it.
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(searchFocused ? 0.09 : 0.06))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(searchFocused ? 0.14 : 0.07),
                                          lineWidth: 0.5)
                    }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: searchFocused)
            if presentationStyle == .classic {
                HStack {
                    Picker("Content Type", selection: $store.contentFilter) {
                        ForEach(ShelfContentFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer(minLength: 2)
                    managementMenu
                }
            }
        }.font(.caption).buttonStyle(.plain)
    }

    private var visibleSelection: Set<UUID> {
        store.selection.intersection(Set(store.visibleItems.map(\.id)))
    }

    private var shelfFooter: some View {
        IslandModuleFooter {
            Button(interaction.isSelecting || !visibleSelection.isEmpty ? "Done" : "Select") {
                setSelectionMode(!(interaction.isSelecting || !visibleSelection.isEmpty))
            }
            .buttonStyle(IslandActionButtonStyle())
            .disabled(store.items.isEmpty)
            .accessibilityIdentifier("shelf.selection.toggle")
            if !visibleSelection.isEmpty {
                Text("\(visibleSelection.count) selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !visibleSelection.isEmpty {
                ShelfQuickActionBar(items: store.visibleItems.filter { visibleSelection.contains($0.id) }, inline: true)
                Button {
                    removeShelfItems(ids: visibleSelection)
                } label: { Image(systemName: "trash") }
                .buttonStyle(IslandHeaderButtonStyle())
                .help("Remove Selected")
                .accessibilityLabel("Remove Selected")
                .accessibilityIdentifier("shelf.selection.remove")
            } else {
                Button { _ = store.undoLastRemoval() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(IslandHeaderButtonStyle())
                .disabled(!store.canUndoRemoval)
                .help("Undo Remove")
                .accessibilityLabel("Undo Remove")
                .accessibilityIdentifier("shelf.undoRemoval")
            }
            Menu {
                Button(allVisibleItemsSelected ? "Deselect All" : "Select All") {
                    if allVisibleItemsSelected {
                        store.clearSelection()
                    } else {
                        setSelectionMode(true)
                        store.selectAllVisible()
                    }
                }
                .disabled(store.visibleItems.isEmpty)
                Button("Undo Remove") { _ = store.undoLastRemoval() }
                    .disabled(!store.canUndoRemoval)
                Divider()
                Button("Clear Shelf", role: .destructive) {
                    removeShelfItems(ids: Set(store.items.map(\.id)))
                }
                .disabled(store.items.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .help("More Shelf Actions")
            .accessibilityLabel("More Shelf Actions")
            .accessibilityIdentifier("shelf.manage")
        }
    }

    private var managementMenu: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                managementAction("Batch Selection", symbol: interaction.isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
                                 identifier: "shelf.selection.toggle", enabled: !store.items.isEmpty,
                                 active: interaction.isSelecting) {
                    setSelectionMode(!interaction.isSelecting)
                }
                managementAction(allVisibleItemsSelected ? "Deselect All" : "Select All",
                                 symbol: allVisibleItemsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack",
                                 identifier: "shelf.selection.all", enabled: !store.visibleItems.isEmpty) {
                    if allVisibleItemsSelected {
                        store.clearSelection()
                    } else {
                        setSelectionMode(true)
                        store.selectAllVisible()
                    }
                }
                managementDivider
                managementAction("Remove Selected", symbol: "trash",
                                 identifier: "shelf.selection.remove", enabled: !visibleSelection.isEmpty,
                                 destructive: true) {
                    removeShelfItems(ids: visibleSelection)
                }
                managementAction("Clear Shelf", symbol: "xmark.bin",
                                 identifier: "shelf.clear", enabled: !store.items.isEmpty,
                                 destructive: true) {
                    removeShelfItems(ids: Set(store.items.map(\.id)))
                }
                managementDivider
                managementAction("Undo Remove", symbol: "arrow.uturn.backward",
                                 identifier: "shelf.undoRemoval", enabled: store.canUndoRemoval) {
                    _ = store.undoLastRemoval()
                }
            }
            .fixedSize()
            .frame(width: showsManagementActions ? 130 : 0, alignment: .trailing)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28),
                       value: showsManagementActions)
            .allowsHitTesting(showsManagementActions)
            .accessibilityHidden(!showsManagementActions)
            Button {
                shelfFocusAction?()
                showsManagementActions.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ShelfIconButtonStyle(active: interaction.isSelecting,
                                              expanded: showsManagementActions))
            .help(Text("Manage Shelf"))
            .accessibilityLabel("Manage Shelf")
            .accessibilityIdentifier("shelf.manage")
        }
    }

    private var managementDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 12)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func managementAction(_ title: LocalizedStringKey, symbol: String,
                                  identifier: String, enabled: Bool, active: Bool = false,
                                  destructive: Bool = false, help: LocalizedStringKey? = nil,
                                  action: @escaping () -> Void) -> some View {
        Button {
            searchFocused = false
            shelfFocusAction?()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShelfIconButtonStyle(active: active, destructive: destructive))
        .disabled(!enabled)
        .help(Text(help ?? title))
        .accessibilityLabel(Text(title))
        .accessibilityValue(active ? Text("Selected") : Text(""))
        .accessibilityIdentifier(identifier)
    }

    private func setSelectionMode(_ enabled: Bool) {
        if enabled {
            collapseStack()
            shelfFocusAction?()
        }
        interaction.setSelectionMode(enabled, in: store)
    }

    private var allVisibleItemsSelected: Bool {
        !store.visibleItems.isEmpty && visibleSelection.count == store.visibleItems.count
    }

    private func removeShelfItems(ids: Set<UUID>) {
        let remove: @MainActor () -> Void = {
            do {
                let removed = try store.removeBatchForUser(ids: ids)
                guard !removed.isEmpty else { return }
                interaction.normalize(for: store.visibleItems)
                quickLookCoordinator?.refreshPreview(contextItem: nil)
                notices.show(.removed)
            } catch {
                notices.show(.removalFailed)
            }
        }
        if let shelfUserRemovalAction {
            shelfUserRemovalAction(remove)
        } else {
            remove()
        }
    }

    private func normalizeSearch() {
        let visible = store.visibleItems
        store.setSelection(store.selection.intersection(Set(visible.map(\.id))))
        interaction.normalize(for: visible)
        gridGeometry.cardFrames = gridGeometry.cardFrames.filter { frame in visible.contains { $0.id == frame.key } }
        dropTargetState.reset()
    }

    private var countCaption: String {
        store.selection.isEmpty
            ? "\(store.items.count)"
            : String(localized: "\(store.selection.count) of \(store.items.count)")
    }

    // MARK: - Grid

    private var itemGrid: some View {
        GeometryReader { viewport in
            // Derive the column count once for this viewport so the scrolling
            // and non-scrolling grid agree; `adaptive` used to drop to two
            // columns inside the slightly narrower scroll container.
            let gridColumns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: Self.gridSpacing, alignment: .top),
                count: ShelfLayoutEngine.gridColumnCount(for: viewport.size.width)
            )
            let fits = presentationStyle == .classic
                && ShelfLayoutEngine.gridFits(itemCount: store.visibleItems.count,
                                              viewport: viewport.size)
            Group {
                if presentationStyle == .island {
                    ScrollViewReader { proxy in
                        IslandModuleScrollView {
                            cardGrid(columns: gridColumns)
                        }
                        .onChange(of: interaction.focusedItemID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: store.duplicateDrop) { _, drop in
                            if let id = store.visibleItems.first(where: { drop?.cardIDs.contains($0.id) == true })?.id {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                } else if fits {
                    cardGrid(columns: gridColumns)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    scrollingGrid(columns: gridColumns)
                }
            }
            // The grid container keeps the pre-selection bounds for a few frames
            // while the quick-action row animates in, so it swallows clicks on
            // the empty area below the cards. Treat a tap here as a background
            // tap; card clicks are owned by their AppKit event layer.
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
            // Change the container immediately; do not keep an outgoing grid
            // alive with the same card IDs and shared drag/selection geometry.
            .animation(nil, value: fits)
        }
    }

    private func scrollingGrid(columns: [GridItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                cardGrid(columns: columns)
            }
            .scrollIndicators(presentationStyle == .island ? .automatic : .hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: interaction.focusedItemID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func cardGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
            ForEach(store.visibleItems) { item in
                gridCell(for: item)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Self.cardAnimation, value: store.items)
        .animation(reduceMotion ? nil : Self.cardAnimation, value: store.selection)
    }

    private func gridCell(for item: ShelfItem) -> some View {
        let index = store.index(ofItemWithID: item.id)
        return cellContent(for: item)
            .overlay {
                RoundedRectangle(cornerRadius: ShelfItemCard.cornerRadius)
                    .fill(Color.accentColor.opacity(duplicateHighlightIDs.contains(item.id) ? 0.18 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: ShelfItemCard.cornerRadius)
                            .strokeBorder(Color.accentColor.opacity(duplicateHighlightIDs.contains(item.id) ? 0.7 : 0), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // C5/C6: report the frame of the card in the window's .global coordinate system (including
            // scroll offset), for use in selection and drag-and-insert positioning; clear when the cell is
            // off-screen or removed to avoid outdated geometry.
            .modifier(ShelfCardGeometryReporter(itemID: item.id))
            // S4: insertion indicator line — drawn on the front edge of the card when insertionIndex is
            // hit.
            .overlay(alignment: .leading) {
                if dropTargetState.insertionIndex != nil, dropTargetState.insertionIndex == index {
                    insertionIndicator
                        .padding(.leading, -(Self.gridSpacing / 2 + 3))
                }
            }
            // S4: insertion indicator line — drawn on the back edge of the last card when the insertion
            // position is at the end.
            .overlay(alignment: .trailing) {
                if dropTargetState.insertionIndex == store.items.count, index == store.items.count - 1 {
                    insertionIndicator
                        .padding(.trailing, -(Self.gridSpacing / 2 + 3))
                }
            }
    }

    @ViewBuilder
    private func cellContent(for item: ShelfItem) -> some View {
        if ShelfStackAvailability.isEnabled, item.kind == .stack {
            ShelfStackView(
                item: item,
                isSelected: store.selection.contains(item.id),
                isKeyboardFocused: interaction.focusedItemID == item.id
                    && (presentationStyle == .classic || interaction.showsKeyboardFocus),
                isExpanded: interaction.expandedStackID == item.id,
                onSelect: { additive in select(item.id, additive: additive) },
                onToggleExpanded: { toggleStackExpansion(item.id) },
                onRemove: { store.removeForUser(ids: [item.id]) },
                onRecover: { toggleStackExpansion(item.id) },
                onCopy: {
                    copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                        anchor: item,
                        visibleItems: store.items,
                        selectedIDs: store.selection
                    ))
                },
                transferStatus: stackTransferStatus(for: item),
                dragContentsProvider: dragContents(for:)
            )
        } else {
            ShelfItemCard(
                item: item,
                isSelected: store.selection.contains(item.id),
                isKeyboardFocused: interaction.focusedItemID == item.id
                    && (presentationStyle == .classic || interaction.showsKeyboardFocus),
                onSelect: { additive in select(item.id, additive: additive) },
                onRemove: { store.removeForUser(ids: [item.id]) },
                onRecover: { itemRecoveryController?.recover(item) },
                onCopy: item.availability == .available
                    ? {
                        copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                            anchor: item,
                            visibleItems: store.items,
                            selectedIDs: store.selection
                        ))
                    }
                    : nil,
                transferStatus: transferStore.accessibilityStatus(for: item.id),
                dragContentsProvider: dragContents(for:)
            )
        }
    }

    /// S5: dragging a top card out of content — if the dragged card is part of the current
    /// multi-selection, the entire batch is dragged out (stack is expanded into sub-items by
    /// DragPayloadBuilder), otherwise only the individual card is dragged.
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let dragged = store.selection.contains(anchor.id) ? store.selectedItems : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: Set(dragged.map(\.id)))
    }

    /// S4: drag-and-insert indicator line (accent vertical bar).
    private var insertionIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4)
            .shadow(color: Color.accentColor.opacity(0.32), radius: 3)
            .allowsHitTesting(false)
    }

    // MARK: - Drop highlight (S4 reserved)

    /// S4: when DragContainerView is hovered over during drag-in, `dropTargetState.isTargeted == true`,
    /// the entire panel is outlined with a light fill to indicate the drop area. F-05: the accent color
    /// changes based on the drag-in mode — copy and reference use accent, ⌘ cut and move use orange (same
    /// color as the card's scissors badge, consistent in semantics).
    @ViewBuilder
    private var dropTargetHighlight: some View {
        if dropTargetState.isTargeted, !dropTargetState.isReordering {
            RoundedRectangle(cornerRadius: settings.appearance.cornerRadius)
                .strokeBorder(dropModeTint, lineWidth: 2)
                .background {
                    RoundedRectangle(cornerRadius: settings.appearance.cornerRadius)
                        .fill(dropModeTint.opacity(0.12))
                }
                .allowsHitTesting(false)
        }
    }

    /// F-05: accent color for drag-in mode.
    private var dropModeTint: Color {
        dropTargetState.mode == .move ? .orange : .accentColor
    }

    /// F-05: mode hint during hover (capsule at the bottom of the panel; notice banner at the top, not
    /// overlapping). Only show a hint for reordering or moving the original file.
    @ViewBuilder
    private var dropModeHint: some View {
        if dropTargetState.isTargeted && (dropTargetState.isReordering || dropTargetState.mode == .move) {
            Text(dropTargetState.isReordering
                 ? String(localized: "Release to reorder")
                 : String(localized: "Release to move the original here ⌘"))
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { Capsule().fill(.regularMaterial) }
                .padding(.bottom, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Collapse button (issue #10)

    /// Collapse direction (pure logic in `ShelfLayoutEngine.innerEdgeHandleSide`); custom free position
    /// mode is nil — collapse button is not displayed.
    private var collapseHandleSide: ShelfLayoutEngine.InnerEdgeHandleSide? {
        guard presentationStyle == .classic else { return nil }
        return ShelfLayoutEngine.innerEdgeHandleSide(for: settings.shelfPosition)
    }

    /// Title bar collapse button. Previously, it was a full chevron column attached to the panel's inner
    /// edge, with single-side widened margins and isolated arrows breaking the panel's left-right symmetry
    /// (issue #10); now it is aligned with the '⋯' management button below, in the same column and style,
    /// with the chevron pointing toward the attached screen edge (the direction of the pull handle).
    private func collapseButton(side: ShelfLayoutEngine.InnerEdgeHandleSide) -> some View {
        Button {
            shelfHideAction?()
        } label: {
            Image(systemName: side == .leading ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShelfIconButtonStyle())
        // Offset the title bar's 8pt horizontal padding: when right-aligned, it aligns with the '⋯' button
        // (28pt wide, attached to the right content edge); when left-aligned, it aligns with the left
        // content edge, matching the 'All' filter below.
        .padding(side == .leading ? .trailing : .leading, -8)
        .padding(.vertical, -3)
        .help(Text("Hide Shelf"))
        .accessibilityLabel(Text("Hide Shelf"))
        .accessibilityIdentifier("shelf.hide.handle")
    }

    // MARK: - Invisible edge area (exclusive model)

    /// Hot zone attached to the side = panel**attached to the screen edge side** (opposite to the inner
    /// edge handle): right anchor → trailing, left anchor → leading; custom is nil (not displayed). This
    /// is where the handle originally was —
    /// the handle appears only when the shelf is hidden, and when the user taps the same point after the
    /// shelf is expanded, it collapses
    /// (Real device verification: 'After tapping the handle to expand, tapping the same location again
    /// does not collapse it').
    private var outerCollapseStripSide: ShelfLayoutEngine.InnerEdgeHandleSide? {
        switch collapseHandleSide {
        case .leading: return .trailing
        case .trailing: return .leading
        case nil: return nil
        }
    }

    private var outerCollapseStripAlignment: Alignment {
        outerCollapseStripSide == .trailing ? .trailing : .leading
    }

    /// Fully invisible hot zone (user explicitly does not want extra visual elements), retains tooltip and
    /// VoiceOver label; width matches the handle (≤ panel margin band 16pt), does not occupy grid width.
    /// Note: Use 0.001 white instead of `Color.clear` —— in practice, clear does not receive hit in this
    /// context
    /// (the inner edge handle works because it has real glyph content).
    @ViewBuilder
    private var outerCollapseStrip: some View {
        if outerCollapseStripSide != nil {
            Button {
                shelfHideAction?()
            } label: {
                Color.white.opacity(0.001)
            }
            .buttonStyle(.plain)
            .frame(width: ShelfLayoutEngine.innerEdgeHandleWidth)
            // The window may be taller than the glass surface (bottom transparent), the hot zone only
            // covers the glass surface portion.
            .frame(maxHeight: reveal?.surfaceHeight.map { $0 + 16 } ?? .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("Hide Shelf"))
            .accessibilityIdentifier("shelf.hide.edge")
            .help(Text("Hide Shelf"))
        }
    }

    // MARK: - Stack expansion

    @ViewBuilder
    private var expandedStackOverlay: some View {
        if ShelfStackAvailability.isEnabled,
           let stackID = interaction.expandedStackID,
           let stack = store.item(withID: stackID),
           stack.kind == .stack {
            // Semi-transparent overlay: click outside to collapse.
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture(perform: collapseStack)
                .overlay {
                    ShelfStackExpandedView(
                        stack: stack,
                        onDismiss: collapseStack,
                        interaction: interaction,
                        // UX4: Child item ✕ removed from stack; after the stack is dissolved/disappears,
                        // this overlay
                        // automatically collapses because item(withID:) returns nil.
                        onRemoveChild: { childID in
                            store.removeChildrenForUser(ids: [childID], fromStack: stackID)
                        },
                        onRecoverChild: { child in
                            itemRecoveryController?.recover(child)
                        },
                        onCopyChild: { child in
                            copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                                anchor: child,
                                visibleItems: stack.children ?? [],
                                selectedIDs: interaction.childSelection
                            ))
                        }
                    )
                    .padding(8)
                }
                .transition(.opacity)
        }
    }

    private func toggleStackExpansion(_ id: UUID) {
        guard ShelfStackAvailability.isEnabled else { return }
        withAnimation(reduceMotion ? nil : Self.cardAnimation) {
            if interaction.expandedStackID == id {
                interaction.exitStack()
            } else if let stack = store.item(withID: id) {
                interaction.enterStack(stack)
            }
        }
    }

    private func collapseStack() {
        withAnimation(reduceMotion ? nil : Self.cardAnimation) {
            interaction.exitStack()
        }
    }

    // MARK: - Selection

    private var topLevelActionItems: [ShelfItem] {
        ShelfActionSelectionResolver.explicitItems(
            topLevelItems: store.items,
            topLevelSelection: store.selection,
            expandedStackID: nil,
            childSelection: []
        )
    }

    private var shouldShowTopLevelQuickActions: Bool {
        !interaction.isSelecting
            && interaction.expandedStackID == nil
            && !dropTargetState.isTargeted
            && ShelfActionCatalog.hasAnyAction(for: topLevelActionItems)
    }

    private func select(_ id: UUID, additive: Bool) {
        searchFocused = false
        shelfFocusAction?()
        interaction.clickSelection(id, in: store.visibleItems, additive: additive,
                                   extending: NSEvent.modifierFlags.contains(.shift), store: store)
        // S6: Quick Look panel open, preview follows selection changes (including ⌘ click to add/remove
        // multiple selections).
        quickLookCoordinator?.refreshPreview(contextItem: store.item(withID: id))
    }

    private func clearSelectionAndCollapse() {
        searchFocused = false
        shelfFocusAction?()
        showsManagementActions = false
        collapseStack()
        interaction.clearActiveSelection(in: store)
        interaction.showsKeyboardFocus = false
    }

    private func copyToClipboard(_ items: [ShelfItem]) {
        let result = ClipboardController.copy(items, bookmarkService: bookmarkService)
        notices.show(ClipboardController.notice(for: result))
    }

    private func stackTransferStatus(for stack: ShelfItem) -> TransferItemAccessibilityStatus? {
        let statuses = (stack.children ?? []).compactMap {
            transferStore.accessibilityStatus(for: $0.id)
        }
        if statuses.contains(.deliveryFailed) { return .deliveryFailed }
        if statuses.contains(.delivering) { return .delivering }
        if statuses.contains(.receiving) { return .receiving }
        if statuses.contains(.destinationAccepted) { return .destinationAccepted }
        if statuses.contains(.delivered) { return .delivered }
        if statuses.contains(.added) { return .added }
        return nil
    }

    /// Executes only actions that remain possible after the source drag
    /// session ends. A failed export is focused instead of claiming that a
    /// retry happened; the user still performs the real drag-out gesture.
    private func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .openStorageRecovery, .locateExternalFile:
            itemRecoveryController?.perform(action)
        case .retryByDraggingOut(let itemID):
            focusRetainedItem(itemID)
        case .dragAgainFromSource, .dismiss:
            break
        }
    }

    private func focusRetainedItem(_ itemID: UUID) {
        if store.item(withID: itemID) != nil {
            interaction.exitStack()
            interaction.focusedItemID = itemID
            store.select(itemID)
            return
        }
        guard let stack = store.items.first(where: {
            $0.kind == .stack && ($0.children ?? []).contains { $0.id == itemID }
        }) else { return }
        store.select(stack.id)
        guard ShelfStackAvailability.isEnabled else {
            interaction.focusedItemID = stack.id
            return
        }
        interaction.enterStack(stack)
        interaction.focusedItemID = itemID
        interaction.childSelection = [itemID]
    }

    // MARK: - Transient feedback

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = notices.current, !dropTargetState.isTargeted {
            ShelfNoticeToast(notice: notice, onPerformRecovery: performRecovery)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        }
    }

}

// MARK: - Preview fixtures

/// SwiftUI Preview mock data: covers file/folder/image/text/url/stale various forms.
/// Path points to system-provided files, ensuring NSWorkspace icons are parseable in preview; thumbnails
/// follow the same QL → icon fallback chain as runtime.
enum ShelfPreviewFixtures {
    @MainActor
    static func makeStore() -> ShelfStore {
        ShelfStore(items: sampleItems())
    }

    static func sampleItems() -> [ShelfItem] {
        let app = ShelfItem(
            kind: .file,
            path: "/System/Library/CoreServices/Finder.app",
            displayName: "Finder",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let folder = ShelfItem(
            kind: .folder,
            path: "/System/Library/CoreServices",
            displayName: "CoreServices"
        )
        let image = ShelfItem(
            kind: .image,
            path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
            displayName: "Finder.icns",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let text = ShelfItem(
            kind: .text,
            displayName: "Release notes draft",
            sourceApp: SourceAppInfo(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            text: "Ship S3 shelf UI: grid, cards, stacks, empty state.\nDrag-in lands in S4."
        )
        let url = ShelfItem(
            kind: .url,
            displayName: "Apple",
            sourceApp: SourceAppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            urlString: "https://www.apple.com"
        )
        var stale = ShelfItem(
            kind: .file,
            path: "/nonexistent/moved-file.png",
            displayName: "moved-file.png"
        )
        stale.isStale = true
        return [app, folder, image, text, url, stale]
    }

    static func sampleStack() -> ShelfItem {
        ShelfItem(
            kind: .stack,
            displayName: "Screenshots",
            children: [
                ShelfItem(
                    kind: .image,
                    path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
                    displayName: "Finder.icns"
                ),
                ShelfItem(
                    kind: .file,
                    path: "/System/Library/CoreServices/Finder.app",
                    displayName: "Finder"
                ),
                ShelfItem(
                    kind: .url,
                    displayName: "Apple",
                    urlString: "https://www.apple.com"
                ),
            ]
        )
    }
}

// MARK: - Previews

#Preview("Shelf with items") {
    ShelfView()
        .environment(ShelfPreviewFixtures.makeStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .environment(TransferStore())
        .frame(width: 320, height: 600)
}

/// Each mounted cell owns its geometry registration. Container changes may
/// dispose an old cell after a new cell with the same item ID has reported.
private struct ShelfCardGeometryReporter: ViewModifier {
    let itemID: UUID
    @Environment(ShelfGridGeometry.self) private var geometry
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            geometry.report(frame, for: itemID, owner: owner)
        }
        .onDisappear { geometry.removeFrame(for: itemID, owner: owner) }
    }
}

#Preview("Empty shelf") {
    ShelfView()
        .environment(ShelfStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .environment(TransferStore())
        .frame(width: 320, height: 600)
}
