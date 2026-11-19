import AppKit
import SwiftUI

private struct ShelfSelectionModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ShelfFocusActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    var shelfFocusAction: (@MainActor () -> Void)? {
        get { self[ShelfFocusActionEnvironmentKey.self] }
        set { self[ShelfFocusActionEnvironmentKey.self] = newValue }
    }
    var shelfSelectionMode: Bool {
        get { self[ShelfSelectionModeEnvironmentKey.self] }
        set { self[ShelfSelectionModeEnvironmentKey.self] = newValue }
    }
}

/// The Shelf module's content in the Panel: search, an equal-width card grid with vertical
/// scrolling, and a footer with selection actions.
///
/// Interactions: single tap for single selection, ⌘ tap to toggle multiple selection, click on empty area
/// to clear selection and collapse Stack; click on Stack card to expand overlay (only one expanded at a
/// time), click outside or tap again to collapse.
///
/// S4: The two reserved states `isDropTargeted` / `dropInsertionIndex` have been consolidated into
/// `@Environment(DropTargetState.self)` (DragContainerView drives the highlight and insertion indicator
/// line); the card insertion animation modifier (spring, response 0.35, damping 0.7) is in place. C6: Card
/// frame is reported via `ShelfGridGeometry` (window .global coordinates), DragContainerView maps the
/// mouse position to row/column insertion index. Shelf notices are posted through `shelfMessenger` and
/// shown in the shared notice pill.
struct ShelfView: View {
    @Environment(ShelfStore.self) private var store

    /// S4: Drag-in hover highlight and insertion indicator line position is driven by DragContainerView
    /// (NSDraggingDestination bridging).
    @Environment(DropTargetState.self) private var dropTargetState
    /// S6: Quick Look session; synchronize open preview when selection changes (nil is no-op).
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    @Environment(\.bookmarkService) private var bookmarkService
    /// C5/C6: Card grid geometry (frame reporting + selection hit + drag-in insertion positioning shared).
    @Environment(ShelfGridGeometry.self) private var gridGeometry
    /// Posts Shelf notices to the notice pill (nil in previews).
    @Environment(\.shelfMessenger) private var shelfMessenger
    /// v1.2: runtime-only asynchronous batch status.
    @Environment(TransferStore.self) private var transferStore
    @Environment(ShelfInteractionState.self) private var interaction
    /// v1.2: unavailable-item actions (external reconnect vs managed recovery).
    @Environment(\.itemRecoveryController) private var itemRecoveryController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shelfFocusAction) private var shelfFocusAction
    @State private var duplicateHighlightIDs: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    /// Card insertion/waymaking animation (§3: spring, response 0.35, damping 0.7).
    static let cardAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let gridSpacing: CGFloat = 12

    var body: some View {
        presentedSurface
            .environment(\.shelfSelectionMode, interaction.isSelecting)
            .environment(\.colorScheme, .dark)
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
            .onChange(of: store.searchQuery) { normalizeSearch() }
            .onChange(of: store.contentFilter) { normalizeSearch() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shelf.root")
    }

    private var presentedSurface: some View {
        Color.clear
            .overlay { content }
            .overlay { expandedStackOverlay }
            .overlay(alignment: .bottom) { dropModeHint }
            .animation(reduceMotion ? nil : Self.cardAnimation,
                       value: interaction.expandedStackID)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: transferStore.hasVisibleActivity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: dropTargetState.mode)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 4) {
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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                           value: showsDuplicateDropOverlay)
            shelfFooter
                .padding(.top, IslandModuleLayout.headerSpacing - 4)
        }
        .background {
            // Clicking the blank area clears the selection and collapses the Stack; card clicks are
            // handled by the card's own event layer.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: clearSelectionAndCollapse)
        }
    }

    /// Keeps the search bar and footer in place when the grid becomes a message.
    private var resultsViewport: some View {
        Color.clear.overlay { results }
    }

    @ViewBuilder
    private var results: some View {
        if store.items.isEmpty {
            IslandEmptyState(title: "Drop files here",
                             message: "Hold ⌘ while dropping to move the original here",
                             systemImage: "tray.and.arrow.down")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("shelf.emptyState")
                .contentShape(Rectangle())
                .onTapGesture(perform: clearSelectionAndCollapse)
        } else if store.visibleItems.isEmpty {
            IslandModuleState(title: "No Results", message: "Try a different search or filter.",
                              systemImage: "magnifyingglass") {
                Button("Clear Search and Filters") {
                    store.searchQuery = ""
                    store.contentFilter = .all
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
        } else {
            itemGrid
        }
    }

    private var showsDuplicateDropOverlay: Bool {
        ShelfDuplicateFeedback.usesFileOverlay
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
        do {
            let removed = try store.removeBatchForUser(ids: ids)
            guard !removed.isEmpty else { return }
            interaction.normalize(for: store.visibleItems)
            quickLookCoordinator?.refreshPreview(contextItem: nil)
            shelfMessenger?.post(.removed)
        } catch {
            shelfMessenger?.post(.removalFailed)
        }
    }

    private func normalizeSearch() {
        let visible = store.visibleItems
        store.setSelection(store.selection.intersection(Set(visible.map(\.id))))
        interaction.normalize(for: visible)
        gridGeometry.cardFrames = gridGeometry.cardFrames.filter { frame in visible.contains { $0.id == frame.key } }
        dropTargetState.reset()
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
            // The grid container keeps the pre-selection bounds for a few frames
            // while the selection footer changes, so it swallows clicks on
            // the empty area below the cards. Treat a tap here as a background
            // tap; card clicks are owned by their AppKit event layer.
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
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
                    && interaction.showsKeyboardFocus,
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
                    && interaction.showsKeyboardFocus,
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

    // MARK: - Drop hint

    /// F-05: mode hint during hover (capsule at the bottom of the panel). Only show a hint for reordering
    /// or moving the original file.
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
        collapseStack()
        interaction.clearActiveSelection(in: store)
        interaction.showsKeyboardFocus = false
    }

    private func copyToClipboard(_ items: [ShelfItem]) {
        let result = ClipboardController.copy(items, bookmarkService: bookmarkService)
        shelfMessenger?.post(ClipboardController.notice(for: result))
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
            interaction.focusRetainedItem(itemID, in: store)
        case .dragAgainFromSource, .dismiss:
            break
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
        .environment(TransferStore())
        .frame(width: 320, height: 600)
}
