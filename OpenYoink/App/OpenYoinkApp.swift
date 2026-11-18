import SwiftUI

@main
struct OpenYoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SettingsWindowController manages the menu bar entry because showSettingsWindow: is unreliable in
        // an LSUIElement app. The SwiftUI Settings scene uses the same content so the system Settings
        // command opens a working window.
        Settings {
            SettingsView()
                .environment(appDelegate.settingsStore)
                .environment(appDelegate.hotKeyMonitor)
                .environment(appDelegate.launchAtLoginController)
                .environment(appDelegate.updateController)
                .environment(appDelegate.storageManagementController)
                .environment(appDelegate.settingsNavigation)
                .environment(appDelegate.supportController)
                .environment(appDelegate.clipboardHistoryStore)
        }
    }
}
