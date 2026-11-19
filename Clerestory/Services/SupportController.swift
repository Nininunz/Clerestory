import AppKit
import Foundation
import Observation

/// Explicit, user-initiated support actions. No report is sent in the
/// background, and the diagnostic snapshot deliberately excludes paths,
/// file names, clipboard data, shelf contents, account identifiers and logs.
@MainActor
@Observable
final class SupportController {
    struct DiagnosticSnapshot: Equatable {
        let version: String
        let build: String
        let operatingSystem: String
        let architecture: String
        let hotKeyEnabled: Bool
        let dragOutRemovalPolicy: SettingsStore.DragOutRemovalPolicy
        let autoUpdateCheckEnabled: Bool
    }

    static let helpURL = URL(string: "https://github.com/Nininunz/Clerestory/blob/main/README.md#quick-start")!
    private static let newIssueURL = URL(string: "https://github.com/Nininunz/Clerestory/issues/new")!

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var diagnosticSummary: String {
        Self.diagnosticSummary(for: snapshot())
    }

    func openHelp() {
        NSWorkspace.shared.open(Self.helpURL)
    }

    func reportIssue() {
        NSWorkspace.shared.open(Self.reportIssueURL(diagnosticSummary: diagnosticSummary))
    }

    @discardableResult
    func copyDiagnosticSummary(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(diagnosticSummary, forType: .string)
    }

    static func diagnosticSummary(for snapshot: DiagnosticSnapshot) -> String {
        """
        Clerestory diagnostics
        Version: \(snapshot.version) (\(snapshot.build))
        macOS: \(snapshot.operatingSystem)
        Architecture: \(snapshot.architecture)
        Global shortcut: \(enabled(snapshot.hotKeyEnabled))
        Drag-out policy: \(snapshot.dragOutRemovalPolicy.rawValue)
        Automatic update checks: \(enabled(snapshot.autoUpdateCheckEnabled))
        """
    }

    static func reportIssueURL(diagnosticSummary: String) -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: """
            ## What happened?


            ## Steps to reproduce
            1.

            ## What did you expect?


            <details>
            <summary>Diagnostic summary (no file names, paths, clipboard or shelf contents)</summary>

            ```text
            \(diagnosticSummary)
            ```
            </details>
            """)
        ]
        return components.url!
    }

    private func snapshot() -> DiagnosticSnapshot {
        let info = Bundle.main.infoDictionary
        return DiagnosticSnapshot(
            version: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            build: info?["CFBundleVersion"] as? String ?? "Unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            hotKeyEnabled: settings.hotKeyEnabled,
            dragOutRemovalPolicy: settings.dragOutRemovalPolicy,
            autoUpdateCheckEnabled: settings.autoUpdateCheckEnabled
        )
    }

    private static func enabled(_ value: Bool) -> String {
        value ? "enabled" : "disabled"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
