import Foundation

/// Something that just happened, shown once in the notice pill and then gone.
///
/// The app tells the user about a module in two ways. If it will still be true in a minute, it is a
/// status; if it describes something that just happened, it is a notice.
struct IslandNotice: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case info, success, warning, error }

    /// Stable within the posting module, such as "copy-paths" or a `ShelfNotice` raw value.
    var key: String
    /// Short text shown in the pill.
    var title: String
    /// Full text for the tooltip and VoiceOver. `nil` uses the title.
    var detail: String? = nil
    var tone: Tone = .info
    /// `nil` uses the symbol for the tone.
    var systemImage: String? = nil
    /// The one button the pill may show.
    var action: IslandNoticeAction? = nil
    /// Visible time in seconds. `nil` means 4 s, or 8 s with an action. Clamped to 2...10 s.
    var duration: TimeInterval? = nil

    /// Tooltip and VoiceOver text.
    var fullText: String { detail ?? title }

    /// The symbol the pill and the notch show: `systemImage`, or the tone's symbol.
    var symbol: String {
        if let systemImage { return systemImage }
        return switch tone {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning, .error: "exclamationmark.triangle.fill"
        }
    }
}

/// The one button a notice may carry. A closed enum keeps notices Equatable and free of closures.
enum IslandNoticeAction: Equatable, Sendable {
    case openStorageRecovery
    case openModule(IslandModuleID)

    var title: String {
        switch self {
        case .openStorageRecovery: String(localized: "Open Recovery")
        case .openModule: String(localized: "Show")
        }
    }

    var help: String {
        switch self {
        case .openStorageRecovery: String(localized: "Open Storage recovery")
        case .openModule: String(localized: "Show this module")
        }
    }
}

/// The only way to write messages. It is bound to one module, so it cannot touch another
/// module's messages.
@MainActor
struct ModuleMessenger {
    let moduleID: IslandModuleID
    // The center lives as long as the app; weak is a safety net.
    private weak var center: IslandMessageCenter?

    init(moduleID: IslandModuleID, center: IslandMessageCenter?) {
        self.moduleID = moduleID
        self.center = center
    }

    /// For previews and tests that don't care about messages. It has no center, so its posts,
    /// statuses and withdrawals go nowhere.
    static let inert = ModuleMessenger(moduleID: .shelf, center: nil)

    /// Whether posts reach a message center. `false` for `inert`.
    var isConnected: Bool { center != nil }

    /// Shows the notice, or queues it behind another module's notice. See `IslandMessageCenter`.
    func post(_ notice: IslandNotice) {
        center?.post(notice, from: moduleID)
    }

    /// Removes this module's visible or waiting notice with this key.
    func withdrawNotice(_ key: String) {
        center?.withdrawNotice(key, from: moduleID)
    }

    /// Adds or updates this module's status with the same key. An equal value changes nothing.
    /// Ignored until the module has started. See `IslandMessageCenter` for raising.
    func setStatus(_ status: IslandStatus) {
        center?.setStatus(status, from: moduleID)
    }

    /// Removes this module's status with this key.
    func clearStatus(_ key: String) {
        center?.clearStatus(key, from: moduleID)
    }

    /// Replaces this module's whole set of statuses in one change. Statuses that stay keep
    /// the time they were raised.
    func setStatuses(_ statuses: [IslandStatus]) {
        center?.setStatuses(statuses, from: moduleID)
    }

    /// This module's statuses that are not dismissed, top first. Empty for `inert`.
    var statuses: [IslandStatus] {
        center?.statuses(for: moduleID) ?? []
    }

    /// Hides this module's dismissible status while the module keeps setting it, for a
    /// control in the module's own page such as System Status "Ignore Once".
    func dismissStatus(_ key: String) {
        center?.dismissStatus(key, of: moduleID)
    }

    /// A value for `IslandStatus.expiresAt`, this far from now on the center's clock.
    func expiry(after duration: Duration) -> Duration {
        (center?.now ?? .zero) + duration
    }
}

extension ModuleMessenger {
    func post(_ notice: ShelfNotice) { post(notice.notice) }
}
