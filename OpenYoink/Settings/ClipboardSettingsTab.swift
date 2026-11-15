import SwiftUI

struct ClipboardSettingsTab: View {
    var body: some View {
        SettingsForm { ClipboardSettingsSections() }
    }
}

struct ClipboardSettingsSections: View {
    @Environment(ClipboardHistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings

    @ViewBuilder
    var body: some View {
        @Bindable var settings = settings
        Section("Clipboard History") {
            Toggle("Record Clipboard", isOn: $settings.clipboardHistoryEnabled)
                .onChange(of: settings.clipboardHistoryEnabled) { _, _ in history.updateRecording() }
            Toggle("Pause Recording", isOn: $settings.clipboardHistoryPaused)
                .disabled(!settings.clipboardHistoryEnabled)
                .onChange(of: settings.clipboardHistoryPaused) { _, _ in history.updateRecording() }
            Picker("Keep History", selection: $settings.clipboardHistoryRetentionDays) {
                Text("1 Day").tag(1)
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
            }
            .onChange(of: settings.clipboardHistoryRetentionDays) { _, _ in history.prune(force: true) }
            Picker("History Limit", selection: $settings.clipboardHistoryEntryLimit) {
                ForEach(ClipboardHistoryPolicy.supportedEntryLimits, id: \.self) { Text("\($0)").tag($0) }
            }
            .onChange(of: settings.clipboardHistoryEntryLimit) { _, _ in history.prune(force: true) }
            LabeledContent("History Shortcut") { ShortcutRecorderView(shortcut: $settings.clipboardHistoryShortcut) }
            if let error = history.shortcutRegistrationError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("Favorites do not expire. Up to 30 favorites and 20 MiB total are kept on this Mac. Privacy markers and ignored apps are skipped; unmarked sensitive text may still be recorded.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Turning recording off keeps saved history. Clear history to delete it.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clipboard History…") { history.onShowWindow?() }
        }

    }
}
