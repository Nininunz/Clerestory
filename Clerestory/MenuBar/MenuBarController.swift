import AppKit

/// Menu bar entry: NSStatusItem + NSMenu.
///
/// The menu contains "Show/Hide Shelf" (checkbox state follows user's preferred Shelf entry expansion
/// state), "Recent Items" submenu (S10, read `RecentItemsService`), "Quick Start", "Usage Help", "Report
/// an Issue", settings, update, and exit. User-visible strings go through `String(localized:)` to
/// Localizable.xcstrings (S10).
@MainActor
final class MenuBarController: NSObject {
    private let settings: SettingsStore
    private let isShelfExpanded: () -> Bool
    private let recents: RecentItemsService
    private let onToggleShelf: () -> Void
    /// S10: Recently dropped items are re-added to the shelf (entry construction in AppDelegate, which
    /// holds shelfStore).
    private let onReaddRecent: (RecentEntry) -> Void
    /// Open the settings window (provided by AppDelegate's SettingsWindowController).
    private let onShowSettings: () -> Void
    private let onShowClipboardHistory: () -> Void
    /// Two-step real drag-and-drop practice that can be replayed.
    private let onShowQuickStart: () -> Void
    /// Open public usage help; does not change app state.
    private let onOpenHelp: () -> Void
    /// User actively opens GitHub Issue with pre-filled diagnostic summary without content and path.
    private let onReportIssue: () -> Void
    /// Sparkle manual check for updates (provided by AppDelegate's UpdateController).
    private let onCheckForUpdates: () -> Void
    /// When automatic installation fails, users can directly open GitHub Releases for manual download.
    private let onOpenManualUpdate: () -> Void

    private let statusItem: NSStatusItem
    private let toggleItem = NSMenuItem()
    /// "Recent Items" parent item; submenu is rebuilt every time the menu is opened (entries change with
    /// each drag-out).
    private let recentParentItem = NSMenuItem()

    init(settings: SettingsStore,
         isShelfExpanded: @escaping () -> Bool,
         recents: RecentItemsService,
         onToggleShelf: @escaping () -> Void,
         onReaddRecent: @escaping (RecentEntry) -> Void,
         onShowSettings: @escaping () -> Void,
         onShowQuickStart: @escaping () -> Void,
         onOpenHelp: @escaping () -> Void,
         onReportIssue: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void,
         onOpenManualUpdate: @escaping () -> Void,
         onShowClipboardHistory: @escaping () -> Void = {}) {
        self.settings = settings
        self.isShelfExpanded = isShelfExpanded
        self.recents = recents
        self.onToggleShelf = onToggleShelf
        self.onReaddRecent = onReaddRecent
        self.onShowSettings = onShowSettings
        self.onShowClipboardHistory = onShowClipboardHistory
        self.onShowQuickStart = onShowQuickStart
        self.onOpenHelp = onOpenHelp
        self.onReportIssue = onReportIssue
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenManualUpdate = onOpenManualUpdate
        // Fixed square width: adaptive width plus wider status bar icon takes about 36pt, which is about a
        // third wider than most menu bar icons; macOS hides icons that don't fit when the menu bar is
        // crowded.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        configureMenu()
        applyVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applyVisibility() {
        statusItem.menu?.items.first { $0.action == #selector(showClipboardHistory(_:)) }?
            .isHidden = !settings.experimentalModulesEnabled
        // Keep Settings reachable if there is no active Island surface.
        statusItem.isVisible = settings.menuBarIconEnabled
            || !settings.islandEnabled
            || IslandScreenCatalog.options().isEmpty
            || IslandDebugMode.simulatesNoNotch
            || (!settings.islandClickRevealEnabled && !settings.islandHoverRevealEnabled)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        applyVisibility()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // Template rendering lets macOS choose the symbol color for light and dark menu bars and for the
        // selected state.
        let image = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                            accessibilityDescription: "Clerestory")
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyDown
    }

    private func configureMenu() {
        let menu = NSMenu()

        toggleItem.action = #selector(toggleShelf(_:))
        toggleItem.target = self
        menu.addItem(toggleItem)


        menu.addItem(.separator())

        // S10: Recent drag-out history submenu (rebuilt every time the menu is opened, see
        // rebuildRecentSubmenu).
        recentParentItem.title = String(localized: "Recent Items")
        recentParentItem.submenu = NSMenu()
        menu.addItem(recentParentItem)

        let clipboardItem = NSMenuItem(title: String(localized: "Clipboard History…"),
                                       action: #selector(showClipboardHistory(_:)), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        let quickStartItem = NSMenuItem(title: String(localized: "Quick Start…"),
                                        action: #selector(showQuickStart(_:)),
                                        keyEquivalent: "")
        quickStartItem.target = self
        menu.addItem(quickStartItem)

        let helpItem = NSMenuItem(title: String(localized: "Usage Help"),
                                  action: #selector(openHelp(_:)),
                                  keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let reportItem = NSMenuItem(title: String(localized: "Report an Issue…"),
                                    action: #selector(reportIssue(_:)),
                                    keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())

        // S8: Open SwiftUI Settings scene (see showSettings(_:) ).
        let settingsItem = NSMenuItem(title: String(localized: "Settings…"),
                                      action: #selector(showSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Sparkle: Manually trigger update check (auto-check switch is in settings-general).
        let updateItem = NSMenuItem(title: String(localized: "Check for Updates…"),
                                    action: #selector(checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let manualUpdateItem = NSMenuItem(title: String(localized: "Download Latest Release…"),
                                          action: #selector(openManualUpdate(_:)),
                                          keyEquivalent: "")
        manualUpdateItem.target = self
        menu.addItem(manualUpdateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit Clerestory"),
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleShelf(_ sender: NSMenuItem) {
        onToggleShelf()
    }


    /// Open the self-managed settings window (`SettingsWindowController`).
    ///
    /// No longer use SwiftUI Settings scene's `showSettingsWindow:`—this action fails silently under
    /// LSUIElement. The self-managed window has no such issue. LSUIElement's focus handling (activate
    /// prerequisite) is managed by SettingsWindowController.show().
    @objc private func showSettings(_ sender: Any?) {
        onShowSettings()
    }

    @objc private func showClipboardHistory(_ sender: Any?) {
        onShowClipboardHistory()
    }

    @objc private func showQuickStart(_ sender: Any?) {
        onShowQuickStart()
    }

    @objc private func openHelp(_ sender: Any?) {
        onOpenHelp()
    }

    @objc private func reportIssue(_ sender: Any?) {
        onReportIssue()
    }

    /// Manually check for updates (Sparkle; if feed is empty, follow the 'Already Up-to-Date' safe path).
    @objc private func checkForUpdates(_ sender: Any?) {
        onCheckForUpdates()
    }

    @objc private func openManualUpdate(_ sender: Any?) {
        onOpenManualUpdate()
    }

    // MARK: - Recent Items submenu (S10)

    /// Rebuild the recent projects submenu: latest first (max 20 guaranteed by RecentItemsService),
    /// entries with type icons; entries with inaccessible files or unable to be restored accurately (text
    /// summary) are grayed out; the tail 'Clear Recent' clears history.
    private func rebuildRecentSubmenu() {
        guard let submenu = recentParentItem.submenu else { return }
        submenu.removeAllItems()
        let entries = recents.entries
        guard !entries.isEmpty else {
            let emptyItem = NSMenuItem(title: String(localized: "No Recent Items"),
                                       action: nil,
                                       keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.displayName,
                                  action: #selector(readdRecent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.image = Self.menuIcon(for: entry)
            item.isEnabled = Self.canReadd(entry)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clearItem = NSMenuItem(title: String(localized: "Clear Recent"),
                                   action: #selector(clearRecent(_:)),
                                   keyEquivalent: "")
        clearItem.target = self
        submenu.addItem(clearItem)
    }

    /// Feasibility of re-adding: file types require the path to still be readable (grayed out if sandboxed
    /// access is denied); URLs must be parseable; text only stores a 100-character summary, stack items
    /// are expanded when dragged out, both cannot be accurately restored, so they are grayed out.
    nonisolated static func canReadd(_ entry: RecentEntry) -> Bool {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return false }
            return FileManager.default.isReadableFile(atPath: path)
        case .url:
            return entry.urlString.flatMap(URL.init(string:)) != nil
        case .text, .stack:
            return false
        }
    }

    /// 16pt icons for submenu entries: file types use NSWorkspace icons, others use SF Symbols.
    private static func menuIcon(for entry: RecentEntry) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let image: NSImage?
        if let path = entry.path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let symbolName = switch entry.kind {
            case .file: "doc"
            case .folder: "folder"
            case .image: "photo"
            case .text: "doc.text"
            case .url: "link"
            case .stack: "square.stack.3d.up"
            }
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        image?.size = size
        return image
    }

    @objc private func readdRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentEntry,
              Self.canReadd(entry) else { return }
        onReaddRecent(entry)
    }

    @objc private func clearRecent(_ sender: NSMenuItem) {
        recents.clear()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Refresh the selected state and titles each time the menu opens (follow the shelf's actual
    /// visibility), and rebuild the recent projects submenu (entries change with drag-out/Clear).
    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.isHidden = IslandScreenCatalog.options().isEmpty
        let isVisible = isShelfExpanded()
        toggleItem.title = isVisible
            ? String(localized: "Hide Panel")
            : String(localized: "Show Panel")
        toggleItem.state = isVisible ? .on : .off
        rebuildRecentSubmenu()
    }
}
