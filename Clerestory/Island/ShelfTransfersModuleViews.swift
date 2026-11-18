import SwiftUI

struct IslandShelfModuleView: View {
    @Environment(ShelfStore.self) private var shelfStore

    private var subtitle: String {
        if !shelfStore.selection.isEmpty {
            return String(localized: "\(shelfStore.selection.count) selected · \(shelfStore.items.count) items")
        }
        if shelfStore.visibleItems.count != shelfStore.items.count {
            return String(localized: "\(shelfStore.visibleItems.count) of \(shelfStore.items.count) items")
        }
        return String(localized: "\(shelfStore.items.count) items")
    }

    var body: some View {
        VStack(spacing: IslandModuleLayout.headerSpacing) {
            IslandModuleHeader(
                title: "Shelf",
                subtitle: subtitle,
                systemImage: "tray.full"
            ) {
                contentFilterMenu
            }
            ShelfView(presentationStyle: .island)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentFilterMenu: some View {
        @Bindable var shelfStore = shelfStore
        let isFiltered = shelfStore.contentFilter != .all
        return Menu {
            Picker("Content Type", selection: $shelfStore.contentFilter) {
                ForEach(ShelfContentFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFiltered ? Color.accentColor : IslandVisualStyle.primaryText)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().fill(isFiltered ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.08)))
        .help("Content Type")
        .accessibilityLabel("Content Type")
        .accessibilityValue(Text(shelfStore.contentFilter.title))
        .accessibilityIdentifier("shelf.contentFilter")
    }
}
struct IslandTransfersView: View {
    @Environment(TransferStore.self) private var transferStore
    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        VStack(spacing: IslandModuleLayout.headerSpacing) {
            IslandModuleHeader(
                title: "Transfers",
                subtitle: transferStore.hasVisibleActivity
                    ? String(localized: "Transferring content…")
                    : String(localized: "No active transfers"),
                systemImage: "arrow.up.arrow.down"
            )
            IslandModuleScrollView(fillsViewport: true) {
                if transferStore.hasVisibleActivity {
                    ShelfActivityStrip(onPerformRecovery: onPerformRecovery)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    IslandEmptyState(
                        title: "All caught up",
                        message: "New imports and deliveries appear here.",
                        systemImage: "checkmark.circle"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
