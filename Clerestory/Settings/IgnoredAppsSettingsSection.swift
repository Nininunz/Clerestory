import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ignored Apps

struct IgnoredAppsSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        Group {
            Section {
                // Plain rows instead of a List: a List is its own scroll view and
                // would swallow scroll-wheel events meant for the Settings page.
                VStack(spacing: 0) {
                    if settings.ignoredAppBundleIDs.isEmpty {
                        Text("No ignored apps")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    } else {
                        ForEach(Array(settings.ignoredAppBundleIDs.enumerated()), id: \.element) { index, bundleID in
                            if index > 0 { Divider() }
                            IgnoredAppRow(bundleID: bundleID) {
                                settings.removeIgnoredApps(bundleIDs: [bundleID])
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

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
    let remove: () -> Void

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
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel(Text("Remove \(displayName)"))
        }
        .padding(.vertical, 6)
    }
}

