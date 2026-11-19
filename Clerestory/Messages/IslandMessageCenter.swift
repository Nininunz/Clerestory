import Foundation
import Observation

/// The one store for messages shown in the notice pill, and the only owner of their timers and
/// announcements. Modules write through a `ModuleMessenger`; the pill, its panel controller and
/// the drag handshake read from here.
///
/// Notice rules:
/// 1. A notice with the same module and key as the visible or a waiting one replaces that copy in
///    place. It does not animate again, and it is not spoken again if its text is unchanged. A
///    replaced visible notice gets its full time again only when nothing waits.
/// 2. A plain notice (no action) replaces a visible plain notice from the same module right away,
///    unless other notices are waiting.
/// 3. Anything else waits in a first-in, first-out queue of up to `queueCapacity`. While anything
///    waits, the visible notice ends once it has been on screen for `handoffDuration`, so no
///    module can hold the pill while others wait.
///
/// Durations count visible time only: the presenter stops the clock while the notice waits,
/// during a drag, and while the pointer rests on a pill with a button.
@MainActor
@Observable
final class IslandMessageCenter {
    struct PostedNotice: Equatable {
        /// Identity of the pill. An in-place replace keeps it, so the pill does not animate or
        /// wait for the panel again.
        let id: UInt64
        /// Bumped by every post, including an in-place replace.
        let revision: UInt64
        let moduleID: IslandModuleID
        let notice: IslandNotice
    }

    /// The notice the pill shows once the presenter can show it.
    private(set) var currentNotice: PostedNotice?
    /// Notices waiting behind `currentNotice`, oldest first.
    private(set) var waitingNotices: [PostedNotice] = []

    /// Default visible time for a notice without an action.
    static let defaultDuration: TimeInterval = 4
    /// Default visible time for a notice with an action.
    static let actionDuration: TimeInterval = 8
    /// Every duration, default or explicit, is clamped to this range.
    static let durationRange: ClosedRange<TimeInterval> = 2...10
    /// While another notice waits, the visible one ends after this much visible time.
    static let handoffDuration: TimeInterval = 2
    static let queueCapacity = 4

    static func duration(for notice: IslandNotice) -> TimeInterval {
        let requested = notice.duration ?? (notice.action == nil ? defaultDuration : actionDuration)
        return min(max(requested, durationRange.lowerBound), durationRange.upperBound)
    }

    /// Routes a notice's button. Set by ShelfWindowController where it creates the pill.
    @ObservationIgnored var routeAction: (@MainActor (IslandNoticeAction) -> Void)?
    /// Shared with ShelfWindowController's transfer announcements so one center de-duplicates
    /// all speech.
    @ObservationIgnored let announcer: AccessibilityAnnouncementCenter
    /// Whether visible time is counting. Starts stopped: a notice posted before any presenter
    /// exists waits for one instead of expiring unseen.
    @ObservationIgnored private(set) var isNoticeClockRunning = false

    @ObservationIgnored private let clock: any MessageClock
    @ObservationIgnored private var lastRevision: UInt64 = 0
    @ObservationIgnored private var lastID: UInt64 = 0
    @ObservationIgnored private var moduleRevisions: [IslandModuleID: UInt64] = [:]
    @ObservationIgnored private var countedVisibleTime: Duration = .zero
    @ObservationIgnored private var clockStartedAt: Duration?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(clock: any MessageClock = SystemMessageClock(),
         announcer: AccessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()) {
        self.clock = clock
        self.announcer = announcer
    }

    func messenger(for moduleID: IslandModuleID) -> ModuleMessenger {
        ModuleMessenger(moduleID: moduleID, center: self)
    }

    /// Revision of the latest notice this module posted, or 0. The drag handshake compares it
    /// before and after a drag.
    func noticeRevision(for moduleID: IslandModuleID) -> UInt64 {
        moduleRevisions[moduleID] ?? 0
    }

    /// Whether a notice from `moduleID` posted after `revision` is the current one.
    func hasNewCurrentNotice(from moduleID: IslandModuleID, since revision: UInt64) -> Bool {
        currentNotice?.moduleID == moduleID && noticeRevision(for: moduleID) != revision
    }

    #if DEBUG
    /// Static fixture: the clock never runs and nothing is spoken.
    static func preview(notice: IslandNotice?, from moduleID: IslandModuleID = .shelf) -> IslandMessageCenter {
        let center = IslandMessageCenter(announcer: AccessibilityAnnouncementCenter { _ in })
        if let notice { center.post(notice, from: moduleID) }
        return center
    }
    #endif

    // MARK: - Posting

    /// Modules call this through `ModuleMessenger.post(_:)`. The notice is spoken now, even if
    /// it has to wait to be seen.
    func post(_ notice: IslandNotice, from moduleID: IslandModuleID) {
        lastRevision &+= 1
        let revision = lastRevision
        moduleRevisions[moduleID] = revision

        if let current = currentNotice, current.moduleID == moduleID, current.notice.key == notice.key {
            let replacement = PostedNotice(id: current.id, revision: revision, moduleID: moduleID, notice: notice)
            announceIfChanged(from: current, to: replacement)
            currentNotice = replacement
            // With nothing waiting it gets its full time again. Otherwise it keeps its visible
            // time, so reposting cannot hold the pill past the handoff.
            if waitingNotices.isEmpty { restartVisibleTime() } else { scheduleExpiry() }
            return
        }
        if let index = waitingNotices.firstIndex(where: { $0.moduleID == moduleID && $0.notice.key == notice.key }) {
            let waiting = waitingNotices[index]
            let replacement = PostedNotice(id: waiting.id, revision: revision, moduleID: moduleID, notice: notice)
            announceIfChanged(from: waiting, to: replacement)
            waitingNotices[index] = replacement
            return
        }

        lastID &+= 1
        let posted = PostedNotice(id: lastID, revision: revision, moduleID: moduleID, notice: notice)
        announcer.announce(AccessibilityAnnouncementPlanner.announcement(for: posted))
        guard let current = currentNotice else {
            show(posted)
            return
        }
        if waitingNotices.isEmpty, current.moduleID == moduleID,
           current.notice.action == nil, notice.action == nil {
            show(posted)
            return
        }
        enqueue(posted)
    }

    /// Modules call this through `ModuleMessenger.withdrawNotice(_:)`. Removes the module's
    /// visible or waiting notice with this key.
    func withdrawNotice(_ key: String, from moduleID: IslandModuleID) {
        if let current = currentNotice, current.moduleID == moduleID, current.notice.key == key {
            showNext()
            return
        }
        let count = waitingNotices.count
        waitingNotices.removeAll { $0.moduleID == moduleID && $0.notice.key == key }
        if waitingNotices.count != count { scheduleExpiry() }
    }

    /// Runs a notice's button, then dismisses the visible notice.
    func perform(_ action: IslandNoticeAction) {
        routeAction?(action)
        if currentNotice != nil { showNext() }
    }

    // MARK: - Visible time

    /// The presenter's only timing input: `false` while the notice waits, during a drag and
    /// while the pointer is over a pill with a button. Remaining time is kept across pauses.
    func setNoticeClockRunning(_ running: Bool) {
        guard isNoticeClockRunning != running else { return }
        let now = clock.now
        if running {
            clockStartedAt = now
        } else {
            countedVisibleTime = visibleTime(at: now)
            clockStartedAt = nil
        }
        isNoticeClockRunning = running
        scheduleExpiry()
    }

    private func visibleTime(at now: Duration) -> Duration {
        countedVisibleTime + (clockStartedAt.map { max(.zero, now - $0) } ?? .zero)
    }

    /// Visible time the current notice may still use, given the queue.
    private func remainingTime(at now: Duration) -> Duration? {
        guard let current = currentNotice else { return nil }
        var limit = Self.duration(for: current.notice)
        if !waitingNotices.isEmpty { limit = min(limit, Self.handoffDuration) }
        return .seconds(limit) - visibleTime(at: now)
    }

    // MARK: - Queue

    private func show(_ posted: PostedNotice) {
        currentNotice = posted
        restartVisibleTime()
    }

    private func showNext() {
        if waitingNotices.isEmpty {
            currentNotice = nil
            restartVisibleTime()
        } else {
            show(waitingNotices.removeFirst())
        }
    }

    private func enqueue(_ posted: PostedNotice) {
        if waitingNotices.count >= Self.queueCapacity {
            // Drop the oldest notice without a button; buttons usually lead to recovery.
            let index = waitingNotices.firstIndex { $0.notice.action == nil } ?? 0
            waitingNotices.remove(at: index)
        }
        waitingNotices.append(posted)
        scheduleExpiry()
    }

    private func restartVisibleTime() {
        countedVisibleTime = .zero
        clockStartedAt = isNoticeClockRunning ? clock.now : nil
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard isNoticeClockRunning, let remaining = remainingTime(at: clock.now) else { return }
        guard remaining > .zero else {
            showNext()
            return
        }
        let deadline = clock.now + remaining
        expiryTask = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expiryDidFire()
        }
    }

    private func expiryDidFire() {
        expiryTask = nil
        guard isNoticeClockRunning, let remaining = remainingTime(at: clock.now) else { return }
        if remaining > .zero { scheduleExpiry() } else { showNext() }
    }

    // MARK: - Speech

    private func announceIfChanged(from old: PostedNotice, to new: PostedNotice) {
        let announcement = AccessibilityAnnouncementPlanner.announcement(for: new)
        guard announcement.message != AccessibilityAnnouncementPlanner.announcement(for: old).message else { return }
        announcer.announce(announcement)
    }
}

extension AccessibilityAnnouncementPlanner {
    /// Every notice is spoken when it is posted. A notice with a button names its action, because
    /// the pill's panel never takes keyboard focus.
    static func announcement(for posted: IslandMessageCenter.PostedNotice) -> AccessibilityAnnouncement {
        let notice = posted.notice
        var message = notice.fullText
        if let action = notice.action {
            message += " " + String(localized: "\(action.title) is available.",
                                    comment: "VoiceOver, after a notice's text. The argument is the notice's button title, such as Open Recovery.")
        }
        let priority: AccessibilityAnnouncement.Priority
        if notice.tone == .error || notice.action != nil {
            priority = .high
        } else if notice.tone == .warning {
            priority = .medium
        } else {
            priority = .low
        }
        return AccessibilityAnnouncement(
            token: "notice.\(posted.moduleID.rawValue).\(notice.key).\(posted.revision)",
            message: message,
            priority: priority
        )
    }
}
