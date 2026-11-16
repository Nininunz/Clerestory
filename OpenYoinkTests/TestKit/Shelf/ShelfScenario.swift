import SwiftUI
@testable import OpenYoink

/// Typed cases replace string comparisons when preparing a Shelf state.
enum ShelfScenario: String, CaseIterable {
    case empty, populated, selected
    case noResults = "no-results"
    case importing, duplicate
    case fileDrag = "file-drag"
    case expandedStack = "expanded-stack"
    case stackSelection = "stack-selection"
    case manyItems = "many-items"
    case longNames = "long-names"
    case textSnippets = "text-snippets"
    case keyboardFocus = "keyboard-focus"

    static var previewCases: [Self] {
        allCases.filter {
            ShelfStackAvailability.isEnabled || ($0 != .expandedStack && $0 != .stackSelection)
        }
    }

    var label: String {
        switch self {
        case .empty: "Empty / drop target"
        case .populated: "Items / search + filter"
        case .selected: "Selected items"
        case .noResults: "No results"
        case .importing: "Import in progress"
        case .duplicate: "Duplicate drag / red outline + blurred files"
        case .fileDrag: "File drag / blue outline"
        case .expandedStack: "Expanded stack"
        case .stackSelection: "Stack child selection"
        case .manyItems: "Many items / scrolling"
        case .longNames: "Long names"
        case .keyboardFocus: "Keyboard focus"
        case .textSnippets: "Text snippets / inline notes"
        }
    }

    @MainActor
    func scenario(context: PreviewContext) -> ModuleScenario {
        ModuleScenario(id: rawValue, label: label) {
            let fixture = try ShelfScenarioFixture(self)
            return ModuleScenarioContent(view: fixture.view(settings: context.settings()), dropTarget: fixture.dropTarget)
        }
    }
}

/// Shared scenario state is accessible to behavioral tests without rendering a view.
@MainActor
final class ShelfScenarioFixture {
    let store: ShelfStore
    let interaction: ShelfInteractionState
    let dropTarget = DropTargetState()
    let transfers: TransferStore

    init(_ scenario: ShelfScenario) throws {
        // Dormant stack fixtures still exercise the retained implementation in unit tests.
        interaction = ShelfInteractionState(stacksEnabled:
            scenario == .expandedStack || scenario == .stackSelection || ShelfStackAvailability.isEnabled)
        let items = try ShelfFixtures.mixedItems()
        let stack = ShelfItem(kind: .stack, displayName: "Project resources", children: Array(items.prefix(3)))
        switch scenario {
        case .empty: store = ShelfStore(items: [])
        case .manyItems: store = ShelfStore(items: try ShelfFixtures.manyFiles())
        case .longNames: store = ShelfStore(items: try ShelfFixtures.longNames())
        case .textSnippets: store = ShelfStore(items: ShelfFixtures.textSnippets())
        case .expandedStack, .stackSelection: store = ShelfStore(items: [stack] + Array(items.suffix(4)))
        default: store = ShelfStore(items: items)
        }
        transfers = TransferStore.preview(phase: scenario == .importing ? .receiving(receivedCount: 2, expectedCount: 5) : nil)
        switch scenario {
        case .fileDrag:
            dropTarget.isTargeted = true
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
