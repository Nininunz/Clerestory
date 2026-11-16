import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

/// Run explicitly to regenerate /tmp/openyoink-module-previews.
/// Captures real module views; fixtures never start services or use standard defaults.
@MainActor
final class IslandModulePreviewTests: XCTestCase {
    private var renderer: ModulePreviewRenderer!
    private let context = PreviewContext()
    private var output: URL { renderer.output }

    func testExportModuleStateCatalog() async throws {
        renderer = try ModulePreviewRenderer()
        defer { context.cleanUp() }
        try await battery()
        try await timer()
        try await media()
        try await ai()
        try await clipboard()
        try await folders()
        try await shelf()
        try await transfers()
        try await system()
        try await quickSettings()
        try renderer.finish()
    }

    private func defaults() -> UserDefaults { context.defaults() }
    private func settings() -> SettingsStore { context.settings() }
    private func entry<V: View>(_ label: String, _ view: V) -> (String, AnyView) { (label, AnyView(view)) }

    private func battery() async throws {
        let states: [(String, PowerSourceMonitor.Snapshot)] = [
            ("On battery", .init(hasBattery: true, percentage: 64, isCharging: false, isConnectedToPower: false, powerWatts: -8.2)),
            ("Charging", .init(hasBattery: true, percentage: 42, isCharging: true, isConnectedToPower: true, powerWatts: 27.4)),
            ("Connected / full", .init(hasBattery: true, percentage: 100, isCharging: false, isConnectedToPower: true, powerWatts: 0)),
            ("Power reading unavailable", .init(hasBattery: true, percentage: 64, isCharging: false, isConnectedToPower: false)),
            ("No internal battery", .unavailable)
        ]
        try await export("battery", "Battery", states.map { entry($0.0, IslandBatteryView().environment(PowerSourceMonitor.preview(snapshot: $0.1))) })
    }
    private func timer() async throws {
        let states: [(String, IslandTimerStore.State)] = [
            ("Ready", .idle), ("Running", .running(endDate: Date().addingTimeInterval(1234), originalDuration: 1500)),
            ("Paused", .paused(remaining: 1234, originalDuration: 1500)), ("Finished", .finished(originalDuration: 1500))
        ]
        var views = states.map { entry($0.0, IslandTimerView().environment(IslandTimerStore.preview(state: $0.1, defaults: defaults()))) }
        views.append(entry("Focus history / empty", IslandTimerView(previewHistory: true).environment(IslandTimerStore.preview(state: .idle, defaults: defaults()))))
        try await export("timer", "Timer", views)
    }
    private func media() async throws {
        let settings = settings()
        var views: [(String, AnyView)] = []
        for (label, availability) in [("Disabled / Enable", NowPlayingModuleStore.Availability.disabled), ("Probing", .probing), ("Nothing playing", .available), ("Unavailable", .unavailable)] {
            views.append(entry(label, IslandNowPlayingView().environment(settings).environment(NowPlayingModuleStore.preview(availability: availability))))
        }
        for playing in [true, false] {
            let snapshot = NowPlayingSnapshot(title: "Evening Light", artist: "Sample Artist", album: "Preview Sessions", isPlaying: playing, sourceName: "Music", duration: 240, elapsedTime: 83)
            views.append(entry(playing ? "Playing / transport controls" : "Paused / transport controls", IslandNowPlayingView().environment(settings).environment(NowPlayingModuleStore.preview(availability: .available, snapshot: snapshot, source: PreviewMediaSource()))))
        }
        try await export("now-playing", "Now Playing", views)
    }
    private func ai() async throws {
        let snapshot = AIUsageSnapshot(summary: .init(today: .init(tokens: 1_250_000, costUSD: 9.75, conversations: 18), last7dTokens: 8_500_000, last7dActiveDays: 5, last30dTokens: 32_000_000, last30dAveragePerActiveDay: 1_280_000, total: nil), limits: .init(windows: [.init(id: "claude.five_hour", provider: "claude", providerName: "Claude", windowLabel: "5 hours", fraction: 0.73, resetsAt: Date().addingTimeInterval(3600))], issues: []), fetchedAt: Date())
        let cases: [(String, AIUsageModuleStore)] = [
            ("Loading", .preview(status: .loading)), ("Ready / dashboard", .preview(status: .ready, snapshot: snapshot)),
            ("Not installed / Download + Retry", .preview(status: .notRunning, installed: false)),
            ("Not running / Open + Retry", .preview(status: .notRunning)),
            ("Failed / Retry", .preview(status: .failed("TokenTracker returned HTTP 503"))),
            ("Refresh failed / cached data + Retry", .preview(status: .failed("TokenTracker returned HTTP 503"), snapshot: snapshot))
        ]
        try await export("ai-usage", "AI Usage", cases.map { entry($0.0, IslandAIUsageView().environment($0.1)) })
    }
    private func clipboard() async throws {
        let entries = [ClipboardHistoryEntry(content: .text("A sample clipboard note")), ClipboardHistoryEntry(content: .url("https://example.com"), isFavorite: true)]
        var views: [(String, AnyView)] = []
        for state in ["Loading", "Empty", "Recording / items", "Paused / items", "Recording off", "No results", "Load failed", "Notice"] {
            let settings = settings()
            settings.clipboardHistoryEnabled = state != "Recording off"
            settings.clipboardHistoryPaused = state == "Paused / items"
            let store = ClipboardHistoryStore.preview(settings: settings, directory: output.appendingPathComponent("clipboard-fixture"), entries: ["Loading", "Empty", "Load failed"].contains(state) ? [] : entries, loading: state == "Loading", error: state == "Load failed" ? "Clipboard history could not be loaded. Clear history to reset it." : nil, notice: state == "Notice" ? "Copied to Clipboard" : nil)
            views.append(entry(state, ClipboardHistoryView.preview(query: state == "No results" ? "no matching item" : "").environment(settings).environment(store)))
        }
        try await export("clipboard", "Clipboard History", views)
    }
    private func folders() async throws {
        let items = ["Documents", "Projects", "Downloads"].map { FavoriteFolder(bookmark: Data(), lastKnownPath: "/Preview/\($0)") }
        var views: [(String, AnyView)] = []
        for state in ["Empty / Add", "Folders / Add + Open", "Unavailable folder", "Load failed / Dismiss", "Duplicate folder notice / Dismiss", "Copying / Cancel"] {
            let store = FavoriteFoldersStore.preview(items: state == "Empty / Add" || state == "Load failed / Dismiss" ? [] : items, unavailable: state == "Unavailable folder", notice: state == "Load failed / Dismiss" ? "Folder favorites could not be loaded. The damaged data was kept for recovery." : state == "Duplicate folder notice / Dismiss" ? "This folder is already in Quick Access." : nil, isError: state == "Load failed / Dismiss")
            views.append(entry(state, FavoriteFoldersModuleView().environment(store).environment(FavoriteFolderDropCoordinator.preview(folders: store, copying: state == "Copying / Cancel")).environment(DropTargetState())))
        }
        try await export("quick-access", "Quick Access", views)
    }
    private func shelf() async throws {
        try await renderer.export("shelf", "Shelf", ShelfScenario.allCases.map { $0.scenario(context: context) })
    }
    private func transfers() async throws {
        let failure = TransferFailure(reason: .externalFileOffline, itemName: "Project.pdf", recoveryAction: .locateExternalFile(itemID: UUID()))
        let phases: [(String, TransferPhase?)] = [
            ("Idle", nil), ("Preparing", .preparing), ("Receiving", .receiving(receivedCount: 2, expectedCount: 5)),
            ("Finalizing", .finalizing), ("Target accepted", .targetAccepted), ("Delivered", .delivered),
            ("Partial success / recovery + Dismiss", .partiallySucceeded(successCount: 4, failures: [failure])),
            ("Failed / Locate + Dismiss", .failed(failure)), ("Cancelled", .cancelled)
        ]
        try await export("transfers", "Transfers", phases.map { entry($0.0, IslandTransfersView(onPerformRecovery: { _ in }).environment(TransferStore.preview(phase: $0.1))) })
    }
    private func system() async throws {
        var snapshot = SystemSnapshot.unavailable()
        snapshot.cpuUsage = 0.23
        snapshot.memoryUsedBytes = 12_000_000_000
        snapshot.memoryTotalBytes = 24_000_000_000
        snapshot.memoryPressure = .normal
        snapshot.diskAvailableBytes = 320_000_000_000
        snapshot.diskTotalBytes = 1_000_000_000_000
        snapshot.networkDownloadBytesPerSecond = 2_400_000
        snapshot.networkUploadBytesPerSecond = 140_000
        snapshot.thermalStatus = .nominal
        snapshot.battery = .init(percentage: 64, isCharging: false, isConnectedToPower: false, powerWatts: -8.2)
        snapshot.topApplications = [.init(id: "preview", processIdentifier: 0, name: "Sample App", bundleIdentifier: nil, cpuUsage: 0.18, memoryBytes: 1_200_000_000)]
        let alert = IslandActivity(id: "preview", moduleID: .system, priority: .systemWarning, title: "High memory pressure", detail: "Memory pressure is elevated.", systemImage: "memorychip", expiresAt: nil)
        try await export("system-status", "System Status", [
            entry("Metrics unavailable", IslandSystemStatusView().environment(SystemStatusModuleStore.preview(snapshot: .unavailable()))),
            entry("Metrics and applications", IslandSystemStatusView().environment(SystemStatusModuleStore.preview(snapshot: snapshot))),
            entry("Alert / View Details + Ignore Once", IslandSystemStatusView().environment(SystemStatusModuleStore.preview(snapshot: snapshot, alerts: [alert])))
        ])
    }
    private func quickSettings() async throws {
        var views: [(String, AnyView)] = []
        for state in ["Default modules", "All modules enabled", "Optional modules disabled"] {
            let settings = settings()
            let registry = IslandModuleRegistry()
            for descriptor in registry.descriptors where !descriptor.isCore && state != "Default modules" {
                settings.setIslandModuleEnabled(state == "All modules enabled", id: descriptor.id)
            }
            registry.apply(settings: settings)
            views.append(entry(state, IslandModuleLibraryView(onOpenSettings: {}).environment(settings).environment(registry).environment(IslandActivityCoordinator())))
        }
        try await export("quick-settings", "Quick Settings", views)
    }

    private final class PreviewMediaSource: NowPlayingSource {
        var supportsTransportControls: Bool { true }
        var supportsSeeking: Bool { true }
        func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void, onFailure: @escaping @MainActor () -> Void) {}
        func stop() {}
        func send(_ command: NowPlayingCommand) async -> Bool { true }
    }

    // Compatibility adapter while other modules migrate to explicit scenario IDs.
    private func export(_ slug: String, _ title: String, _ states: [(String, AnyView)]) async throws {
        try await renderer.export(slug, title, states.map { label, view in
            ModuleScenario(id: label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "-"), label: label, makeView: { view })
        })
    }
}
