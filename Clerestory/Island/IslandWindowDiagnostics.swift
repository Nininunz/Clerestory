import AppKit
import CoreGraphics

/// Read-only checks for #112, where AppKit reports the expanded panel as visible
/// but the window server never puts it on screen. Nothing here changes a window.
enum IslandWindowDiagnostics {
    /// What the window server reports for one window.
    struct WindowServerState: Equatable, Sendable {
        var isOnScreen: Bool
        var layer: Int
        var alpha: Double
    }

    /// Returns nil when the window server has no entry for the window, for
    /// example just after it is first ordered in. Uses the full window list:
    /// a window that is ordered in but off screen (#112) only appears there.
    static func windowServerState(windowNumber: Int) -> WindowServerState? {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber })
        else { return nil }
        return WindowServerState(
            isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1
        )
    }

    /// True when AppKit has the window ordered in but the window server
    /// doesn't show it. An unknown window server state is not reported.
    static func isMissingFromScreen(appKitVisible: Bool, windowServer: WindowServerState?) -> Bool {
        guard appKitVisible, let windowServer else { return false }
        return !windowServer.isOnScreen
    }

    /// A short, non-identifying description of the window's display.
    @MainActor static func displayDescription(for screen: NSScreen?) -> String {
        guard let screen else { return "none" }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let builtIn = number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        return "\(number?.stringValue ?? "?")\(builtIn ? "-builtin" : "")"
    }

    /// Formats the window server state for a log line.
    static func describe(_ state: WindowServerState?) -> String {
        guard let state else { return "unknown" }
        return "\(state.isOnScreen ? "yes" : "no") layer=\(state.layer) alpha=\(state.alpha)"
    }

    /// Workspace notifications that can change whether a window reaches the screen.
    static let workspaceEvents: [Notification.Name] = [
        NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification,
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ]

    /// Screen lock and unlock are only posted as distributed notifications.
    static let distributedEvents: [Notification.Name] = [
        Notification.Name("com.apple.screenIsLocked"),
        Notification.Name("com.apple.screenIsUnlocked"),
    ]
}
