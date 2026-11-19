import CoreGraphics

/// Routing façade over the Panel's Shelf for the app delegate, menu and shortcuts.
@MainActor
final class ShelfPresentationCoordinator {
    private let windowController: ShelfWindowController

    init(windowController: ShelfWindowController) {
        self.windowController = windowController
    }

    var isExpanded: Bool { windowController.isPreferredShelfExpanded }
    var isIslandExpanded: Bool { windowController.isIslandExpanded }

    func applyCurrentMode(animated: Bool = false) {
        windowController.applyPresentationSettings(animated: animated)
    }

    func toggle(animated: Bool = true) {
        windowController.toggleShelf(animated: animated)
    }

    func toggleForKeyboard(animated: Bool = true) {
        windowController.toggleShelfForKeyboard(animated: animated)
    }

    func show(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        windowController.showPreferredShelf(animated: animated,
                                            takeKeyboardFocus: takeKeyboardFocus)
    }

    func hide(animated: Bool = true) {
        windowController.hidePreferredShelf(animated: animated)
    }

    func showIslandShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        windowController.showIslandShelf(animated: animated,
                                         takeKeyboardFocus: takeKeyboardFocus)
    }

    func collapseIsland(animated: Bool = true) {
        windowController.collapseIsland(animated: animated)
    }

    @discardableResult
    func dragApproachedTop(at point: CGPoint) -> Bool {
        windowController.islandDragApproachedTop(at: point)
    }

    func dragEnded(imported: Bool, hasPendingNotice: Bool = false) {
        windowController.islandDragEnded(imported: imported, hasPendingNotice: hasPendingNotice)
    }

    func shutdown() {
        windowController.shutdown()
    }
}
