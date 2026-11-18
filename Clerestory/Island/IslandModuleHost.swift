import SwiftUI

/// The module boundary shared by the live Island and isolated scenario windows.
/// The surrounding surface supplies islandSurfaceHeight for content measurement.
struct IslandModuleHost<Content: View>: View {
    let descriptor: IslandModuleDescriptor?
    let coordinator: IslandActivityCoordinator
    @ViewBuilder var content: Content

    var extensionContext: IslandModuleExtensionContext? {
        guard let descriptor, descriptor.supportsExtendedHeight else { return nil }
        return IslandModuleExtensionContext(
            isExtended: Binding(get: { coordinator.isModuleExtended(descriptor) },
                                set: { coordinator.setModuleExtended($0, descriptor: descriptor) }),
            reportHeight: { coordinator.recordModuleContentHeight($0, descriptor: descriptor) }
        )
    }

    var body: some View {
        content.environment(\.islandModuleExtension, extensionContext)
    }
}
