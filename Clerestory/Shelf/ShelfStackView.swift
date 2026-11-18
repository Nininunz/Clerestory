import SwiftUI

/// Stack card (Implementation Plan §3: top-right count badge).
///
/// Reuse appearance `ShelfItemCard` (12pt rounded corners, selected state), thumbnail takes the real
/// thumbnail of the first file-like child item, or show stack placeholder if none; overlay count badge on
/// top-right.
///
/// Click semantics: regular click = single-select the Stack and expand/collapse the overlay; ⌘ click =
/// only toggle selection (multi-select semantics same as regular card, no expansion). The expanded overlay
/// is presented by ShelfView.
struct ShelfStackView: View {
    @Environment(\.shelfSelectionMode) private var selectionMode
    let item: ShelfItem
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    /// While the overlay is expanded: the card remains accent highlighted, indicating 'click again to
    /// collapse'.
    let isExpanded: Bool
    /// additive being true indicates ⌘ click (toggle selection), otherwise single-select.
    let onSelect: (_ additive: Bool) -> Void
    let onToggleExpanded: () -> Void
    var onRemove: (() -> Void)?
    var onRecover: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var transferStatus: TransferItemAccessibilityStatus? = nil
    /// S5 drag-out content calculation (multi-select batch/stack semantics determined by ShelfView).
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    var body: some View {
        ShelfItemCard(
            item: item,
            isSelected: isSelected || (!selectionMode && isExpanded),
            isKeyboardFocused: isKeyboardFocused,
            onSelect: { additive in
                if selectionMode || additive || NSEvent.modifierFlags.contains(.shift) {
                    onSelect(true)
                } else {
                    onSelect(false)
                    onToggleExpanded()
                }
            },
            onRemove: onRemove,
            onRecover: onRecover,
            onCopy: onCopy,
            transferStatus: transferStatus,
            thumbnailItem: item.children?.first(where: { $0.fileURL != nil }),
            dragContentsProvider: dragContentsProvider
        )
        .overlay(alignment: selectionMode ? .topLeading : .topTrailing) { countBadge }
    }

    /// Count badge (accent capsule, top-right).
    private var countBadge: some View {
        Text("\(item.children?.count ?? 0)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background { Capsule().fill(Color.accentColor) }
            .padding(5)
            .allowsHitTesting(false)
    }
}

/// Stack expanded overlay (§3: .ultraThinMaterial background + evenly spaced grid layout of children).
///
/// Hosted by ShelfView as full area overlay (clicking the external mask collapses it). Children support
/// multi-select (⌘ click to toggle, regular click to single-select), selections stored in shared
/// `ShelfInteractionState` — children are not part of the top-level `ShelfStore.items`, so they do not
/// follow store.selection.
/// S5: child cards can be dragged out (dragged out in batch when child selection is hit); dragging out a
/// child does not remove it from the stack (removal semantics designed with S6's stack batch operations).
/// UX4: child card hover ✕ removed from the stack via `onRemoveChild` callback
/// (`ShelfStore.removeChild(_:fromStack:)`: if only one item remains, it automatically disbands into a
/// regular item; if zero items remain, the stack is removed; after the stack disappears, the overlay is
/// automatically collapsed by ShelfView).
struct ShelfStackExpandedView: View {
    @Environment(ShelfStore.self) private var store
    @Environment(TransferStore.self) private var transferStore
    @Environment(DropTargetState.self) private var dropTargetState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shelfSelectionMode) private var selectionMode
    let stack: ShelfItem
    let onDismiss: () -> Void
    let interaction: ShelfInteractionState
    /// UX4: Callback for removing a child item (parameter is child item id). nil means the child card is
    /// not rendered ✕.
    var onRemoveChild: ((UUID) -> Void)?
    /// v1.2: child-specific availability recovery.
    var onRecoverChild: ((ShelfItem) -> Void)? = nil
    var onCopyChild: ((ShelfItem) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(stack.children ?? []) { child in
                            ShelfItemCard(
                                item: child,
                                isSelected: interaction.childSelection.contains(child.id),
                                isKeyboardFocused: interaction.focusedItemID == child.id && interaction.showsKeyboardFocus,
                                onSelect: { additive in
                                    interaction.clickSelection(child.id, in: stack.children ?? [],
                                                               additive: selectionMode || additive,
                                                               extending: NSEvent.modifierFlags.contains(.shift),
                                                               store: store)
                                },
                                onRemove: onRemoveChild.map { remove in
                                    { remove(child.id) }
                                },
                                onRecover: onRecoverChild.map { recover in
                                    { recover(child) }
                                },
                                onCopy: child.availability == .available
                                    ? onCopyChild.map { copy in { copy(child) } }
                                    : nil,
                                transferStatus: transferStore.accessibilityStatus(for: child.id),
                                dragContentsProvider: dragContents(for:)
                            )
                        }
                    }
                    .padding(2)
                    .animation(reduceMotion ? nil : ShelfView.cardAnimation,
                               value: interaction.childSelection)
                    .animation(reduceMotion ? nil : ShelfView.cardAnimation,
                               value: stack.children)
                }
                .onChange(of: interaction.focusedItemID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: 320)
            if shouldShowQuickActions {
                ShelfQuickActionBar(items: selectedActionItems)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    /// S5: Dragging out a child item —— batch if multiple selection is hit, otherwise single item;
    /// topLevelIDs is empty (child items are not removed from stack).
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let children = stack.children ?? []
        let dragged = interaction.childSelection.contains(anchor.id) && interaction.childSelection.count > 1
            ? children.filter { interaction.childSelection.contains($0.id) }
            : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: [])
    }

    private var selectedActionItems: [ShelfItem] {
        (stack.children ?? []).filter { interaction.childSelection.contains($0.id) }
    }

    private var shouldShowQuickActions: Bool {
        !dropTargetState.isTargeted
            && ShelfActionCatalog.hasAnyAction(for: selectedActionItems)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(stack.displayName)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(stack.children?.count ?? 0) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse stack")
            .accessibilityLabel(Text("Collapse stack"))
            .accessibilityIdentifier("shelf.stack.\(stack.id.uuidString).collapse")
        }
    }
}
