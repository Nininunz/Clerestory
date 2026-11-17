import AppKit

enum IslandWindowRole { case expanded, notch }

@MainActor
final class IslandExpandedWindowController {
    private let makePanel: () -> ShelfPanel
    lazy var panel: ShelfPanel = {
        let panel = makePanel()
        panel.interactionInset = IslandSurfaceShadow.inset
        panel.interactionCornerRadius = 26
        panel.hasShadow = false
        return panel
    }()
    init(makePanel: @escaping () -> ShelfPanel) { self.makePanel = makePanel }

    func configure() {
        panel.acceptsKeyboardFocus = true
        panel.allowsTopEdgeOverlap = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
    }

    func updatePointer(at point: CGPoint) {
        panel.ignoresMouseEvents = !panel.containsInteractionPoint(point)
    }

    func hide() {
        panel.hasShadow = false
        panel.orderOut(nil)
    }
}

@MainActor
final class IslandNotchWindowController {
    private let makePanel: () -> ShelfPanel
    lazy var panel = makePanel()
    init(makePanel: @escaping () -> ShelfPanel) { self.makePanel = makePanel }

    func update(layout: IslandGeometryResolver.Layout, enabled: Bool, level: NSWindow.Level) {
        guard enabled, layout.notchIsVisible else { hide(); return }
        panel.acceptsKeyboardFocus = false
        panel.allowsTopEdgeOverlap = true
        panel.level = level
        panel.hasShadow = false
        if panel.frame != layout.notchFrame { panel.setFrame(layout.notchFrame, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() { panel.orderOut(nil) }
}
