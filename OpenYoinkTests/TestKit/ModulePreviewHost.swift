import SwiftUI
@testable import OpenYoink

@MainActor
struct ModulePreviewCapture {
    let scenario: ModuleScenario
    let extended: Bool
    let supportsExtension: Bool
    var id: String { supportsExtension ? "\(scenario.id)-\(extended ? "extended" : "regular")" : scenario.id }
    var label: String { supportsExtension ? "\(scenario.label) / \(extended ? "Extended" : "Regular")" : scenario.label }
}

/// Uses the production module host, coordinator, surface, and geometry resolver.
/// Only the navigation strip and screen dimensions are fixture inputs.
@MainActor
struct ModulePreviewHost: View {
    let descriptor: IslandModuleDescriptor
    let coordinator: IslandActivityCoordinator
    let content: AnyView
    var dropTarget: DropTargetState? = nil

    static let screen = IslandGeometryResolver.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 32, width: 1512, height: 918),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 666, height: 32),
        auxiliaryTopRightArea: CGRect(x: 846, y: 950, width: 666, height: 32))

    var size: CGSize {
        IslandGeometryResolver.resolve(screen: Self.screen,
            preferredExpandedHeight: coordinator.preferredExpandedHeight(for: descriptor)).expandedFrame.size
    }

    var body: some View {
        IslandExpandedSurface(hasPhysicalNotch: true) {
            Color.clear.frame(height: 32 + IslandGeometryResolver.physicalNotchClickExtension)
        } content: {
            GeometryReader { geometry in
                IslandModuleHost(descriptor: descriptor, coordinator: coordinator) { content }
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .overlay {
            if let dropTarget {
                IslandDropOutline(progress: 1,
                    collapsedSize: IslandGeometryResolver.resolve(screen: Self.screen).compactFrame.size,
                    attachedToScreenTop: true, state: dropTarget)
            }
        }
        .environment(\.islandSurfaceHeight, size.height)
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
    }

    static func descriptor(for slug: String) -> IslandModuleDescriptor? {
        let ids: [String: IslandModuleID] = [
            "shelf": .shelf, "quick-settings": .quickSettings, "battery": .battery,
            "timer": .timer, "now-playing": .media, "ai-usage": .aiUsage,
            "clipboard": .clipboard, "quick-access": .folders,
            "transfers": .transfers, "system-status": .system
        ]
        return ids[slug].flatMap { IslandModuleRegistry().descriptor(for: $0) }
    }
}
