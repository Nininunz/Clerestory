import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ignored Apps

struct IgnoredAppsSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selection: Set<String> = []
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section {
                List(selection: $selection) {
                    ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID).tag(bundleID)
                    }
                }
                .frame(height: 160)
                .onDeleteCommand {
                    settings.removeIgnoredApps(bundleIDs: selection)
                    selection.removeAll()
                }

                HStack {
                    Menu("Add…") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button {
                                if let bundleID = app.bundleIdentifier {
                                    settings.addIgnoredApp(bundleID: bundleID)
                                }
                            } label: {
                                Label {
                                    Text(app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown"))
                                } icon: {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Choose Application…") { chooseApplication() }
                    }
                    .fixedSize()

                    Spacer()

                    Button("Remove") {
                        settings.removeIgnoredApps(bundleIDs: selection)
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                }
            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("Drag triggers are suppressed while these apps are frontmost. Clipboard recording also skips them. Keyboard shortcuts still work.")
                    .font(.caption)
            }
        }
        .onAppear { reloadRunningApps() }
    }

    private func reloadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// NSOpenPanel on /Applications — sandbox-legal because the user picks the
    /// app explicitly (user-selected read entitlement).
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.addIgnoredApp(bundleID: bundleID)
    }
}

/// One ignore-list entry: app icon, display name, bundle identifier. Icon and
/// name resolve through NSWorkspace even when the app isn't running; an app
/// that can no longer be located degrades to a dashed placeholder + raw ID.
private struct IgnoredAppRow: View {
    let bundleID: String

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let appURL else { return bundleID }
        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

