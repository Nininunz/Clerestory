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
    var notices: ShelfNoticeModel? = nil

    static let screen = IslandGeometryResolver.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 32, width: 1512, height: 918),
        safeAreaTop: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 666, height: 32),
        auxiliaryTopRightArea: CGRect(x: 846, y: 950, width: 666, height: 32))

    var surfaceSize: CGSize {
        IslandGeometryResolver.resolve(screen: Self.screen,
            preferredExpandedHeight: coordinator.preferredExpandedHeight(for: descriptor)).expandedFrame.size
    }

    private var notice: ShelfNoticeContent? {
        var presentation = ShelfNoticePresentation()
        let phase = presentation.update(revision: notices?.current == nil ? nil : notices?.revision,
            context: .init(isEnabled: true, surface: .pinned, isTransitioning: false,
                           isDragging: dropTarget?.isTargeted == true))
        return phase == .visible ? notices?.current : nil
    }

    var size: CGSize {
        var result = surfaceSize
        if let notice {
            result.height += ShelfNoticePlacement.gap + ShelfNoticePlacement.pillSize(for: notice).height
                + ShelfNoticePlacement.shadowInset
        }
        return result
    }

    var body: some View {
        VStack(spacing: ShelfNoticePlacement.gap) {
            surface
            if let notice {
                ShelfNoticeToast(notice: notice, onPerformRecovery: { _ in })
                    .frame(width: ShelfNoticePlacement.width)
                    .padding(.bottom, ShelfNoticePlacement.shadowInset)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var surface: some View {
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
        .environment(\.islandSurfaceHeight, surfaceSize.height)
        .environment(\.colorScheme, .dark)
        .frame(width: surfaceSize.width, height: surfaceSize.height)
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
