import SwiftUI
@testable import OpenYoink

/// Typed cases replace string comparisons when preparing a Shelf state.
enum ShelfScenario: String, CaseIterable {
    case empty, populated, selected
    case noResults = "no-results"
    case importing, duplicate
    case expandedStack = "expanded-stack"
    case stackSelection = "stack-selection"
    case manyItems = "many-items"
    case longNames = "long-names"
    case keyboardFocus = "keyboard-focus"

    var label: String {
        switch self {
        case .empty: "Empty / drop target"
        case .populated: "Items / search + filter"
        case .selected: "Selected items"
        case .noResults: "No results"
        case .importing: "Import in progress"
        case .duplicate: "Duplicate drop / blurred files"
        case .expandedStack: "Expanded stack"
        case .stackSelection: "Stack child selection"
        case .manyItems: "Many items / scrolling"
        case .longNames: "Long names"
        case .keyboardFocus: "Keyboard focus"
        }
    }

    @MainActor
    func scenario(context: PreviewContext) -> ModuleScenario {
        ModuleScenario(id: rawValue, label: label) {
            try ShelfScenarioFixture(self).view(settings: context.settings())
        }
    }
}

/// Shared scenario state is accessible to behavioral tests without rendering a view.
@MainActor
final class ShelfScenarioFixture {
    let store: ShelfStore
    let interaction = ShelfInteractionState()
    let dropTarget = DropTargetState()
    let transfers: TransferStore

    init(_ scenario: ShelfScenario) throws {
        let items = try ShelfFixtures.mixedItems()
        let stack = ShelfItem(kind: .stack, displayName: "Project resources", children: Array(items.prefix(3)))
        switch scenario {
        case .empty: store = ShelfStore(items: [])
        case .manyItems: store = ShelfStore(items: ShelfFixtures.notes(count: 40))
        case .longNames: store = ShelfStore(items: ShelfFixtures.longNames())
        case .expandedStack, .stackSelection: store = ShelfStore(items: [stack] + Array(items.suffix(4)))
        default: store = ShelfStore(items: items)
        }
        transfers = TransferStore.preview(phase: scenario == .importing ? .receiving(receivedCount: 2, expectedCount: 5) : nil)
        switch scenario {
        case .duplicate:
            dropTarget.isTargeted = true
            dropTarget.hasDuplicateFiles = true
        case .expandedStack, .stackSelection:
            store.select(stack.id)
            interaction.enterStack(stack)
            if scenario == .stackSelection { interaction.childSelection = [items[0].id, items[1].id] }
        case .keyboardFocus:
            interaction.moveSelection(in: items, from: 0, to: 1, extending: false, store: store)
        case .noResults: store.searchQuery = "no matching item"
        case .selected:
            store.select(items[0].id)
            store.select(items[1].id, additive: true)
        default: break
        }
    }

    func view(settings: SettingsStore) -> AnyView {
        AnyView(IslandShelfModuleView().environment(store).environment(settings)
            .environment(dropTarget).environment(ShelfGridGeometry()).environment(ShelfNoticeModel())
            .environment(interaction).environment(transfers))
    }
}
