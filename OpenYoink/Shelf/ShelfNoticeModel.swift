import Foundation
import Observation

/// Transient Shelf feedback. Presentation carries semantics rather than guessing
/// an icon from localized text; full details remain available for accessibility.
@MainActor
@Observable
final class ShelfNoticeModel {
    /// Latest feedback; the panel decides when it can first become visible.
    private(set) var current: ShelfNoticeContent?
    private(set) var revision: UInt64 = 0
    var message: String? { current?.details ?? current?.message }

    /// Visible duration in seconds, excluding time queued for presentation.
    static let displayDuration: TimeInterval = 4

    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var presentationDeferred = false

    func show(_ notice: ShelfNoticeMessage) { show(notice.presentation) }

    #if DEBUG
    /// Static fixture: no dismissal timer and no runtime services.
    static func preview(notice: ShelfNoticeContent?) -> ShelfNoticeModel {
        let model = ShelfNoticeModel()
        model.current = notice
        return model
    }
    #endif

    /// New feedback replaces the previous notice and starts a fresh lifetime.
    func show(_ message: String) {
        show(ShelfNoticeContent(message: message, kind: .info))
    }

    func show(_ notice: ShelfNoticeContent) {
        dismissalTask?.cancel()
        revision &+= 1
        self.current = notice
        scheduleDismissal()
    }

    /// Queued feedback gets its full display duration once it can actually appear.
    func setPresentationDeferred(_ deferred: Bool) {
        guard presentationDeferred != deferred else { return }
        presentationDeferred = deferred
        dismissalTask?.cancel()
        if !deferred { scheduleDismissal() }
    }

    private func scheduleDismissal() {
        guard current != nil, !presentationDeferred else { return }
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}
