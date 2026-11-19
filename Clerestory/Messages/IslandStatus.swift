import Foundation

/// A condition that stays true until its module clears it, such as "Battery low" or "Timer
/// finished". It shows in the notch as the module's icon, tint and VoiceOver label.
///
/// The app tells the user about a module in two ways. If it will still be true in a minute, it is a
/// status; if it describes something that just happened, it is a notice.
///
/// A status is *raised* when it is new, its tone goes up, or its title changes. A raised
/// `warning` or `critical` status that `announcesWhenRaised` is spoken once and shows its text
/// once in the notice pill. A change to the detail only, such as 18% becoming 17%, is silent.
struct IslandStatus: Equatable, Sendable {
    enum Tone: Int, Comparable, Sendable {
        case neutral, progress, warning, critical

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Unique within the module that sets it, such as "low" or "finished".
    var key: String
    var title: String
    /// A short value, such as "15%". Changing only the detail never announces.
    var detail: String? = nil
    var systemImage: String
    var tone: Tone = .neutral
    /// Whether raising a `warning` or `critical` status is spoken and shown once in the pill.
    var announcesWhenRaised = true
    /// Whether the user can hide it while the module keeps setting it.
    var isDismissible = false
    /// When the center removes it on its own. A point on the message center's `MessageClock`
    /// timeline (a `Duration` since the clock's origin, not a wall-clock date), so it is never
    /// stretched by changes to the system clock. Get one from `ModuleMessenger.expiry(after:)`.
    var expiresAt: Duration? = nil

    /// The pill text for its one-off notice, such as "Battery low · 15%".
    var pillText: String { Self.pillText(title: title, detail: detail) }
    /// What VoiceOver says when it is raised, such as "Battery low, 15%".
    var spokenText: String { Self.spokenText(title: title, detail: detail) }

    static func pillText(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return String(localized: "\(title) · \(detail)",
                      comment: "Notice pill text: a title and its value, such as Battery low · 15%.")
    }

    static func spokenText(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return String(localized: "\(title), \(detail)",
                      comment: "VoiceOver text that joins a title and its value, such as Battery low, 15%.")
    }
}

extension IslandNotice.Tone {
    /// The notch tint a notice uses while it is on screen.
    var statusTone: IslandStatus.Tone {
        switch self {
        case .info, .success: .neutral
        case .warning: .warning
        case .error: .critical
        }
    }
}
