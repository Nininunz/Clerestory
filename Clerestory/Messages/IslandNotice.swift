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
    /// Visible time in seconds. `nil` uses the message center's default.
    var duration: TimeInterval? = nil

    /// Tooltip and VoiceOver text.
    var fullText: String { detail ?? title }
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

    /// For previews and tests that don't care about messages. It has no center, so its posts
    /// and withdrawals go nowhere.
    static let inert = ModuleMessenger(moduleID: .shelf, center: nil)

    /// Whether posts reach a message center. `false` for `inert`.
    var isConnected: Bool { center != nil }

    /// The newest notice replaces the current one.
    func post(_ notice: IslandNotice) {
        center?.post(notice, from: moduleID)
    }

    /// Clears the current notice only if this module posted it with this key.
    func withdrawNotice(_ key: String) {
        center?.withdrawNotice(key, from: moduleID)
    }
}

extension ModuleMessenger {
    func post(_ notice: ShelfNotice) { post(notice.notice) }
}
