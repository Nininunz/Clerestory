import Foundation
import Observation

/// The one store for messages shown in the notice pill. Modules write through a
/// `ModuleMessenger`; the pill, its panel controller and the drag handshake read from here.
/// Presentation carries semantics rather than guessing an icon from localized text; full
/// details remain available for accessibility.
@MainActor
@Observable
final class IslandMessageCenter {
    struct PostedNotice: Equatable {
        let revision: UInt64
        let moduleID: IslandModuleID
        let notice: IslandNotice
    }

    /// Latest notice; the panel decides when it can first become visible.
    private(set) var current: PostedNotice?
    private(set) var revision: UInt64 = 0

    /// Default visible duration in seconds, excluding time queued for presentation.
    static let displayDuration: TimeInterval = 4

    /// Routes a notice's button. Set by ShelfWindowController where it creates the pill.
    @ObservationIgnored var routeAction: (@MainActor (IslandNoticeAction) -> Void)?

    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var presentationDeferred = false

    func messenger(for moduleID: IslandModuleID) -> ModuleMessenger {
        ModuleMessenger(moduleID: moduleID, center: self)
    }

    #if DEBUG
    /// Static fixture: no dismissal timer and no runtime services.
    static func preview(notice: IslandNotice?, from moduleID: IslandModuleID = .shelf) -> IslandMessageCenter {
        let center = IslandMessageCenter()
        if let notice {
            center.revision = 1
            center.current = PostedNotice(revision: 1, moduleID: moduleID, notice: notice)
        }
        return center
    }
    #endif

    /// New feedback replaces the previous notice and starts a fresh lifetime.
    /// Modules call this through `ModuleMessenger.post(_:)`.
    func post(_ notice: IslandNotice, from moduleID: IslandModuleID) {
        dismissalTask?.cancel()
        revision &+= 1
        current = PostedNotice(revision: revision, moduleID: moduleID, notice: notice)
        scheduleDismissal()
    }

    /// Modules call this through `ModuleMessenger.withdrawNotice(_:)`.
    func withdrawNotice(_ key: String, from moduleID: IslandModuleID) {
        guard let current, current.moduleID == moduleID, current.notice.key == key else { return }
        dismissalTask?.cancel()
        self.current = nil
    }

    /// Runs a notice's button, then dismisses the pill.
    func perform(_ action: IslandNoticeAction) {
        routeAction?(action)
        dismissalTask?.cancel()
        current = nil
    }

    /// Queued feedback gets its full display duration once it can actually appear.
    func setPresentationDeferred(_ deferred: Bool) {
        guard presentationDeferred != deferred else { return }
        presentationDeferred = deferred
        dismissalTask?.cancel()
        if !deferred { scheduleDismissal() }
    }

    private func scheduleDismissal() {
        guard let current, !presentationDeferred else { return }
        let duration = current.notice.duration ?? Self.displayDuration
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}
