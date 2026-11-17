import AppKit
import ColorSync

struct IslandScreenSelectionCandidate: Equatable {
    let id: String
    let frame: CGRect
    let isMain: Bool
    var hasPhysicalNotch: Bool = true
}

/// Keep the floating Island implementation for the external-display rework.
enum FloatingIslandAvailability {
    static var isEnabled: Bool { IslandDebugMode.simulatesNoNotch }
}

enum IslandDebugMode {
    private static let simulateNoNotchKey = "OpenYoinkSimulateNoNotch"

    static var simulatesNoNotch: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: simulateNoNotchKey)
        #else
        false
        #endif
    }

    #if DEBUG
    static func setSimulatesNoNotch(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: simulateNoNotchKey)
    }
    #endif
}

enum IslandScreenSelectionPolicy {
    static func selectedID(
        for target: SettingsStore.IslandDisplayTarget,
        pointerPoint: CGPoint,
        screens: [IslandScreenSelectionCandidate],
        allowFloating: Bool = FloatingIslandAvailability.isEnabled
    ) -> String? {
        let supportedScreens = screens.filter {
            allowFloating || $0.hasPhysicalNotch
        }
        guard !supportedScreens.isEmpty else { return nil }

        switch target {
        case .main:
            return supportedScreens.first(where: \.isMain)?.id ?? supportedScreens[0].id
        case .automatic:
            return supportedScreens.first(where: { $0.frame.contains(pointerPoint) })?.id
                ?? supportedScreens.first(where: \.isMain)?.id
                ?? supportedScreens[0].id
        case let .display(id):
            // Keep the stored physical-display choice when it is disconnected.
            // Runtime placement temporarily falls back to the main display;
            // reconnecting the display makes the same ID resolve again.
            return supportedScreens.contains(where: { $0.id == id })
                ? id
                : supportedScreens.first(where: \.isMain)?.id ?? supportedScreens[0].id
        }
    }
}

@MainActor
enum IslandScreenCatalog {
    struct Option: Identifiable, Equatable {
        let id: String
        let name: String
        let isMain: Bool
    }

    static func options() -> [Option] {
        NSScreen.screens.enumerated().filter { _, screen in
            FloatingIslandAvailability.isEnabled || hasPhysicalNotch(screen)
        }.map { index, screen in
            Option(id: identifier(for: screen),
                   name: screen.localizedName,
                   isMain: index == 0)
        }
    }

    static func selectedScreen(
        for target: SettingsStore.IslandDisplayTarget,
        pointerPoint: CGPoint
    ) -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.enumerated().map { index, screen in
            IslandScreenSelectionCandidate(
                id: identifier(for: screen),
                frame: screen.frame,
                isMain: index == 0,
                hasPhysicalNotch: hasPhysicalNotch(screen)
            )
        }
        guard let selectedID = IslandScreenSelectionPolicy.selectedID(
            for: target,
            pointerPoint: pointerPoint,
            screens: candidates
        ) else { return nil }
        return screens.first { identifier(for: $0) == selectedID }
    }

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        IslandGeometryResolver.resolve(screen: geometry(for: screen)).hasPhysicalNotch
    }

    static func geometry(for screen: NSScreen)
        -> IslandGeometryResolver.ScreenGeometry {
        // Lets a notched Mac exercise the floating (no-notch) Island:
        // `open OpenYoink.app --args -OpenYoinkSimulateNoNotch YES`
        // or `defaults write com.weijue.OpenYoink OpenYoinkSimulateNoNotch -bool YES`.
        if IslandDebugMode.simulatesNoNotch {
            return IslandGeometryResolver.ScreenGeometry(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaTop: 0,
                auxiliaryTopLeftArea: .zero,
                auxiliaryTopRightArea: .zero
            )
        }
        return IslandGeometryResolver.ScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero
        )
    }

    static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return "frame:\(Int(screen.frame.minX)):\(Int(screen.frame.minY)):"
                + "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display:\(displayID)"
    }
}
