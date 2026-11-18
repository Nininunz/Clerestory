import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - About

struct AboutSettingsTab: View {
    @Environment(SupportController.self) private var support
    @State private var didCopyDiagnostics = false

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Version", value: AppBuildInfo.versionString)
                LabeledContent("License", value: "MIT")
            }

            Section("Acknowledgments") {
                Text("Clerestory is based on OpenYoink by weijue and contributors. Bundled third-party components are Sparkle (MIT) for updates and mediaremote-adapter (BSD 3-Clause) for the optional local Now Playing module. A complete attribution record is available in THIRD_PARTY_NOTICES.md in the source repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Support") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { supportButtons }
                    VStack(alignment: .leading, spacing: 8) { supportButtons }
                }
                Text("Diagnostics include only the app version, macOS, architecture, and relevant setting states. They never include file names, paths, clipboard data, shelf contents, or user identifiers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var supportButtons: some View {
        Button("Usage Help") { support.openHelp() }
            .accessibilityIdentifier("settings.support.help")
        Button("Report an Issue…") { support.reportIssue() }
            .accessibilityIdentifier("settings.support.report")
        Button(didCopyDiagnostics
               ? String(localized: "Copied")
               : String(localized: "Copy Diagnostic Summary")) {
            didCopyDiagnostics = support.copyDiagnosticSummary()
        }
        .accessibilityIdentifier("settings.support.copyDiagnostics")
    }
}
