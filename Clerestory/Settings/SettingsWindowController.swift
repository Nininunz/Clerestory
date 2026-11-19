import AppKit
import SwiftUI

/// Self-managed settings window (the host window for SettingsView).
///
/// Why not use SwiftUI `Settings` scene's `showSettingsWindow:`: In LSUIElement background agent,
/// this action depends on handlers dynamically installed by the scene in the responder chain, and it's
/// tested
/// as silently failing (menu clicked but no response). Self-managed NSWindowController is fully
/// controllable:
/// create once, repeat open only does prep + activate.
@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let hotKeyMonitor: HotKeyMonitor
    private let launchAtLoginController: LaunchAtLoginController
    private let updateController: UpdateController
    private let storageManagementController: StorageManagementController
    private let navigation: SettingsNavigationModel
    private let supportController: SupportController
    private let clipboardHistoryStore: ClipboardHistoryStore
    private var window: NSWindow?

    init(settings: SettingsStore,
         hotKeyMonitor: HotKeyMonitor,
         launchAtLoginController: LaunchAtLoginController,
         updateController: UpdateController,
         storageManagementController: StorageManagementController,
         navigation: SettingsNavigationModel,
         supportController: SupportController,
         clipboardHistoryStore: ClipboardHistoryStore) {
        self.settings = settings
        self.hotKeyMonitor = hotKeyMonitor
        self.launchAtLoginController = launchAtLoginController
        self.updateController = updateController
        self.storageManagementController = storageManagementController
        self.navigation = navigation
        self.supportController = supportController
        self.clipboardHistoryStore = clipboardHistoryStore
    }

    /// Show the settings window and activate the app (LSUIElement: window fronting and keyboard focus both
    /// depend on explicit
    /// activate; repeated calls are idempotent — if window exists, only front it).
    func show(pane: SettingsPane? = nil) {
        if let pane {
            navigation.open(pane)
            if pane == .storage {
                storageManagementController.refresh()
            }
        }
        if window == nil {
            let rootView = SettingsView()
                .environment(settings)
                .environment(hotKeyMonitor)
                .environment(launchAtLoginController)
                .environment(updateController)
                .environment(storageManagementController)
                .environment(navigation)
                .environment(supportController)
                .environment(clipboardHistoryStore)
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.view.setAccessibilityLabel(
                String(localized: "Clerestory Settings")
            )

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Clerestory Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // Sidebar needs a stable minimum width; allow continued expansion, long text and accessibility
            // font sizes
            // will naturally take more space, rather than being cramped with the top navigation.
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ClerestorySettings")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
