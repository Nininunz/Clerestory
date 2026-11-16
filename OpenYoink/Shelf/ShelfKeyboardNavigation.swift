import Foundation
import Observation

enum ShelfArrowDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// Pure grid navigation shared by the panel keyboard handler and tests.
enum ShelfKeyboardNavigator {
    static func destinationIndex(currentIndex: Int,
                                 itemCount: Int,
                                 columnCount: Int,
                                 direction: ShelfArrowDirection) -> Int {
        guard itemCount > 0 else { return 0 }
        let current = min(max(currentIndex, 0), itemCount - 1)
        let columns = max(1, columnCount)
        let proposed: Int
        switch direction {
        case .left: proposed = current - 1
        case .right: proposed = current + 1
        case .up: proposed = current - columns
        case .down: proposed = current + columns
        }
        return min(max(proposed, 0), itemCount - 1)
    }
}

/// Stack implementation is retained for a future grouping UI.
enum ShelfStackAvailability {
    static let isEnabled = false
}

/// Runtime-only keyboard focus and expanded-stack interaction state.
/// Focus is intentionally independent from ShelfStore.selection.
@MainActor
@Observable
final class ShelfInteractionState {
    let stacksEnabled: Bool

    init(stacksEnabled: Bool = ShelfStackAvailability.isEnabled) {
        self.stacksEnabled = stacksEnabled
    }

    var isSelecting = false {
        didSet {
            if oldValue != isSelecting { onActionSelectionDidChange?() }
        }
    }
    var showsKeyboardFocus = false
    var selectionAnchorID: UUID?
    var focusedItemID: UUID?
    var expandedStackID: UUID? {
        didSet {
            if oldValue != expandedStackID { onActionSelectionDidChange?() }
        }
    }
    var childSelection: Set<UUID> = [] {
        didSet {
            if oldValue != childSelection { onActionSelectionDidChange?() }
        }
    }

    /// Expanded-stack selection also controls quick-action visibility. The
    /// controller uses this callback solely for compact-height recalculation.
    var onActionSelectionDidChange: (@MainActor () -> Void)?

    func moveSelection(in items: [ShelfItem], from current: Int, to destination: Int,
                       extending: Bool, store: ShelfStore) {
        guard items.indices.contains(current), items.indices.contains(destination) else { return }
        showsKeyboardFocus = true
        focusedItemID = items[destination].id
        let ids: Set<UUID>
        if extending {
            let anchor = selectionAnchorID.flatMap { id in items.firstIndex { $0.id == id } } ?? current
            selectionAnchorID = items[anchor].id
            ids = Set(items[min(anchor, destination)...max(anchor, destination)].map(\.id))
        } else {
            selectionAnchorID = nil
            ids = [items[destination].id]
        }
        if expandedStackID != nil { childSelection = ids }
        else { store.setSelection(ids) }
    }

    func clickSelection(_ id: UUID, in items: [ShelfItem], additive: Bool,
                        extending: Bool, store: ShelfStore) {
        guard let destination = items.firstIndex(where: { $0.id == id }) else { return }
        if extending {
            let current = focusedItemID.flatMap { focused in items.firstIndex { $0.id == focused } }
                ?? destination
            moveSelection(in: items, from: current, to: destination, extending: true, store: store)
        } else {
            selectionAnchorID = id
            focusedItemID = id
            if expandedStackID != nil {
                if additive || isSelecting { childSelection.formSymmetricDifference([id]) }
                else { childSelection = [id] }
            } else if additive || isSelecting {
                store.toggleSelection(id)
            } else {
                store.select(id)
            }
        }
        showsKeyboardFocus = false
    }

    /// Escape clears the active selection before dismissing its container.
    @discardableResult
    func clearActiveSelection(in store: ShelfStore) -> Bool {
        let hasSelection = expandedStackID == nil ? !store.selection.isEmpty : !childSelection.isEmpty
        guard hasSelection || isSelecting else { return false }
        isSelecting = false
        selectionAnchorID = nil
        focusedItemID = nil
        showsKeyboardFocus = false
        if expandedStackID != nil { childSelection.removeAll() }
        else { store.clearSelection() }
        return true
    }

    func setSelectionMode(_ enabled: Bool, in store: ShelfStore) {
        selectionAnchorID = nil
        isSelecting = enabled
        if !enabled { store.clearSelection() }
    }

    func visibleItems(in topLevelItems: [ShelfItem]) -> [ShelfItem] {
        guard let expandedStackID,
              let stack = topLevelItems.first(where: { $0.id == expandedStackID }),
              stack.kind == .stack else {
            return topLevelItems
        }
        return stack.children ?? []
    }

    func enterStack(_ stack: ShelfItem) {
        guard stacksEnabled else { return }
        selectionAnchorID = nil
        guard stack.kind == .stack, let children = stack.children, !children.isEmpty else { return }
        isSelecting = false
        expandedStackID = stack.id
        childSelection.removeAll()
        focusedItemID = children[0].id
    }

    func exitStack() {
        selectionAnchorID = nil
        let returningFocus = expandedStackID
        expandedStackID = nil
        childSelection.removeAll()
        focusedItemID = returningFocus
    }

    func normalize(for topLevelItems: [ShelfItem]) {
        if let expandedStackID {
            guard let stack = topLevelItems.first(where: { $0.id == expandedStackID }),
                  stack.kind == .stack else {
                self.expandedStackID = nil
                childSelection.removeAll()
                focusedItemID = topLevelItems.first?.id
                return
            }
            let childIDs = Set((stack.children ?? []).map(\.id))
            childSelection.formIntersection(childIDs)
            if let focusedItemID, childIDs.contains(focusedItemID) { return }
            focusedItemID = stack.children?.first?.id
            return
        }

        let topLevelIDs = Set(topLevelItems.map(\.id))
        if let focusedItemID, topLevelIDs.contains(focusedItemID) { return }
        self.focusedItemID = nil
    }
}
