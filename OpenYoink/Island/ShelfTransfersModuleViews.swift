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
            )
            ShelfView(presentationStyle: .island)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
