import Foundation

/// What the notch's leading icon shows in place of its module's default symbol.
struct IslandNotchIndicator: Equatable {
    let systemImage: String
    /// Critical is red, warning orange, progress the accent colour and neutral white.
    let tint: IslandStatus.Tone
    /// Added to the notch's VoiceOver label in order: the status the notch shows, or keeps
    /// showing under a notice or a drag, then the notice or the drag, such as
    /// ["Battery low", "Power connected, 15%"].
    let accessibilityTexts: [String]

    init(systemImage: String, tint: IslandStatus.Tone, accessibilityText: String...) {
        self.init(systemImage: systemImage, tint: tint, accessibilityTexts: accessibilityText)
    }

    init(systemImage: String, tint: IslandStatus.Tone, accessibilityTexts: [String]) {
        self.systemImage = systemImage
        self.tint = tint
        self.accessibilityTexts = accessibilityTexts
    }

    /// The texts joined, such as "Battery low, Power connected, 15%".
    var accessibilityText: String {
        accessibilityTexts.dropFirst().reduce(accessibilityTexts.first ?? "") {
            IslandStatus.spokenText(title: $0, detail: $1)
        }
    }
}

/// Chooses the notch's indicator from the message center, without AppKit, so it is unit-tested.
@MainActor
enum IslandNotchIndicatorResolver {
    static let dragSystemImage = "arrow.down.to.line"

    /// For the module the notch displays (`nil` for the fallback display), the first match wins:
    /// 1. its notice on screen (symbol, tone); a notice that waits does not count;
    /// 2. the drag arrow, in accent, if the display is Shelf and a drag is in progress;
    /// 3. its top status of warning or critical tone;
    /// 4. any other module's critical status, so a critical condition is never hidden by the
    ///    choice of display (only critical ones are borrowed);
    /// 5. its neutral or progress status.
    /// `nil` means the default icon at reduced opacity. The VoiceOver text always starts with
    /// the status that steps 3 to 5 choose, so a notice or a drag never hides it from VoiceOver.
    static func resolve(display: IslandModuleID?, center: IslandMessageCenter,
                        isDragInProgress: Bool) -> IslandNotchIndicator? {
        let status = statusIndicator(display: display, center: center)
        let statusTexts = status?.accessibilityTexts ?? []
        if let display, let posted = center.visibleNotice, posted.moduleID == display {
            return IslandNotchIndicator(systemImage: posted.notice.symbol,
                                        tint: posted.notice.tone.statusTone,
                                        accessibilityTexts: statusTexts + [posted.notice.fullText])
        }
        if display == .shelf, isDragInProgress {
            return IslandNotchIndicator(systemImage: dragSystemImage, tint: .progress,
                                        accessibilityTexts: statusTexts + [String(localized: "Drop into Clerestory")])
        }
        return status
    }

    /// The module whose critical status the icon borrows (step 4 of `resolve`), or `nil` when the
    /// icon shows the display's own notice, drag arrow or status. While it is borrowed, the notch
    /// shows that module's value, such as the battery percentage, in place of its display's own.
    static func borrowedModule(display: IslandModuleID?, center: IslandMessageCenter,
                               isDragInProgress: Bool) -> IslandModuleID? {
        // Steps 1 and 2 of `resolve` cover the status.
        if let display, center.visibleNotice?.moduleID == display { return nil }
        if display == .shelf, isDragInProgress { return nil }
        return chosenStatus(display: display, center: center)?.borrowedFrom
    }

    /// Steps 3 to 5 of `resolve`.
    private static func statusIndicator(display: IslandModuleID?,
                                        center: IslandMessageCenter) -> IslandNotchIndicator? {
        chosenStatus(display: display, center: center).map { indicator(for: $0.status) }
    }

    /// Steps 3 to 5 of `resolve`: the status and, in step 4, the module it is borrowed from.
    private static func chosenStatus(display: IslandModuleID?, center: IslandMessageCenter)
        -> (status: IslandStatus, borrowedFrom: IslandModuleID?)? {
        let top = display.flatMap(center.topStatus(for:))
        if let top, top.tone >= .warning { return (top, nil) }
        if let borrowed = center.latestCriticalStatus(excluding: display) {
            return (borrowed.status, borrowed.moduleID)
        }
        return top.map { ($0, nil) }
    }

    /// The notch's VoiceOver label: its display's label, plus each of the indicator's texts the
    /// label does not already say, for example "Battery, 15 percent, Battery low".
    static func accessibilityLabel(_ label: String, indicator: IslandNotchIndicator?) -> String {
        (indicator?.accessibilityTexts ?? [])
            .filter { !$0.isEmpty && !label.contains($0) }
            .reduce(label) { IslandStatus.spokenText(title: $0, detail: $1) }
    }

    private static func indicator(for status: IslandStatus) -> IslandNotchIndicator {
        IslandNotchIndicator(systemImage: status.systemImage, tint: status.tone,
                             accessibilityText: status.title)
    }
}
