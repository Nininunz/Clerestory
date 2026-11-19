import Foundation
import Observation

/// The one store for messages: the statuses modules set and the notices they post, both
/// through a `ModuleMessenger`. It is the only owner of their timers and announcements. The
/// notch, the notice pill, its panel controller and the drag handshake read from here.
///
/// Statuses and notices are kept apart, so a notice can never remove a status.
///
/// Statuses:
/// 1. Each module has its own set, by key. Setting an equal value changes nothing, not even
///    for observers. A module that has not started (`moduleDidStart`) cannot set statuses, and
///    `moduleDidStop` clears its set.
/// 2. A status is *raised* when it is new, its tone goes up, or its tone stays and its level
///    goes up. A raised `warning` or `critical` status that `announcesWhenRaised` is spoken once
///    ("title, detail") and queues one notice with its text (key `status.<key>`). That notice is
///    withdrawn when its module is, or becomes, the module shown in the panel, or when the
///    status clears first. Any other change, to the title, the detail or a lower level, is
///    silent.
/// 3. A dismissed status stays hidden while its module keeps setting it. Once the module
///    clears it, the next raise shows it again.
/// 4. Within a module, the top status has the highest tone, then the highest level, then the
///    latest raise, then the lowest key.
///
/// Notice rules:
/// 1. A notice with the same module and key as the visible or a waiting one replaces that copy in
///    place. It does not animate again, and it is not spoken again if its text is unchanged. A
///    replaced visible notice gets its full time again only when nothing ready waits.
/// 2. A plain notice (no action, not from a raised status) replaces a visible plain notice from
///    the same module right away, unless a ready notice waits.
/// 3. Anything else waits in a first-in, first-out queue of up to `queueCapacity`. While a
///    ready notice waits, the visible notice ends once it has been on screen for
///    `handoffDuration`, so no module can hold the pill while others wait.
///
/// The shown module: while an unpinned panel shows a module, notices from other modules wait
/// for it to close (see `IslandNoticePresentation`); they are not *ready*. A notice from the
/// shown module goes ahead of them, even ahead of a current notice that has not appeared yet.
/// The others keep their order and show once the panel closes.
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
        /// The key of the raised status this notice shows, or `nil` for a notice a module posted.
        let raisedStatusKey: String?

        /// No button and not from a raised status, so a newer plain notice may replace it.
        var isPlain: Bool { notice.action == nil && raisedStatusKey == nil }
    }

    private struct StatusEntry: Equatable {
        var status: IslandStatus
        /// Larger is more recent. A counter rather than a time, so two raises never tie.
        var raiseOrder: UInt64
        var isDismissed = false
    }

    /// The notice the pill shows once the presenter can show it.
    private(set) var currentNotice: PostedNotice?
    /// Notices waiting behind `currentNotice`, oldest first, except that the shown module's
    /// notices go first while others wait for the panel to close.
    private(set) var waitingNotices: [PostedNotice] = []
    /// Statuses by module and key. The notch observes it.
    private var statusEntries: [IslandModuleID: [String: StatusEntry]] = [:]
    /// The id of the notice the pill shows right now, set by the presenter. The notch observes it.
    private(set) var visibleNoticeID: UInt64?

    /// Default visible time for a notice without an action.
    static let defaultDuration: TimeInterval = 4
    /// Default visible time for a notice with an action.
    static let actionDuration: TimeInterval = 8
    /// Every duration, default or explicit, is clamped to this range.
    static let durationRange: ClosedRange<TimeInterval> = 2...10
    /// While another notice is ready, the visible one ends after this much visible time.
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
    /// The module the expanded panel shows, or `nil`. Set by the presenter.
    @ObservationIgnored private(set) var shownModule: IslandModuleID?
    /// Whether notices from other modules wait for the panel to close (it is not pinned).
    @ObservationIgnored private(set) var othersWaitForShownModule = false
    /// Modules that may set statuses. Notices are never gated.
    @ObservationIgnored private(set) var startedModules: Set<IslandModuleID> = []

    @ObservationIgnored private let clock: any MessageClock
    @ObservationIgnored private var lastRevision: UInt64 = 0
    @ObservationIgnored private var lastID: UInt64 = 0
    @ObservationIgnored private var lastRaise: UInt64 = 0
    @ObservationIgnored private var moduleRevisions: [IslandModuleID: UInt64] = [:]
    @ObservationIgnored private var countedVisibleTime: Duration = .zero
    @ObservationIgnored private var clockStartedAt: Duration?
    @ObservationIgnored private var appearedNoticeID: UInt64?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var statusExpiryTask: Task<Void, Never>?

    init(clock: any MessageClock = SystemMessageClock(),
         announcer: AccessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()) {
        self.clock = clock
        self.announcer = announcer
    }

    func messenger(for moduleID: IslandModuleID) -> ModuleMessenger {
        ModuleMessenger(moduleID: moduleID, center: self)
    }

    /// Now on the center's clock, the timeline of `IslandStatus.expiresAt`.
    var now: Duration { clock.now }

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
    /// Static fixture: the notice is on screen, the clock never runs and nothing is spoken.
    static func preview(notice: IslandNotice?, from moduleID: IslandModuleID = .shelf) -> IslandMessageCenter {
        let center = IslandMessageCenter(announcer: AccessibilityAnnouncementCenter { _ in })
        if let notice { center.post(notice, from: moduleID) }
        center.setVisibleNotice(center.currentNotice?.id)
        return center
    }
    #endif

    // MARK: - Lifecycle

    /// IslandModuleContainer calls this before the module's `start()`, so a status set while
    /// starting is accepted.
    func moduleDidStart(_ moduleID: IslandModuleID) {
        startedModules.insert(moduleID)
    }

    /// IslandModuleContainer calls this after the module's `stop()`. It clears the module's
    /// statuses and the pills of their raises that have not appeared; a pill already on screen
    /// finishes, and the module's other notices still show.
    func moduleDidStop(_ moduleID: IslandModuleID) {
        startedModules.remove(moduleID)
        if statusEntries[moduleID] != nil {
            statusEntries[moduleID] = nil
            scheduleStatusExpiry()
        }
        // Its statuses are gone, so their pills go too, unless one is already on screen. Other
        // notices report something that already happened and still show: the Panel stops every
        // module when it deactivates, and Shelf's startup recovery notices must survive that.
        let isPendingStatusPill = { (posted: PostedNotice) in
            posted.moduleID == moduleID && posted.raisedStatusKey != nil
        }
        let count = waitingNotices.count
        waitingNotices.removeAll(where: isPendingStatusPill)
        if let current = currentNotice, isPendingStatusPill(current), !currentHasAppeared {
            showNext()
        } else if waitingNotices.count != count {
            scheduleExpiry()
        }
    }

    func isModuleStarted(_ moduleID: IslandModuleID) -> Bool {
        startedModules.contains(moduleID)
    }

    // MARK: - Statuses

    /// The module's statuses that are not dismissed, top first.
    func statuses(for moduleID: IslandModuleID) -> [IslandStatus] {
        visibleEntries(for: moduleID).map(\.status)
    }

    func topStatus(for moduleID: IslandModuleID) -> IslandStatus? {
        visibleEntries(for: moduleID).first?.status
    }

    /// The most recently raised critical status of any module other than `moduleID`. The notch
    /// borrows it, so a critical condition shows whatever module the notch displays.
    func latestCriticalStatus(excluding moduleID: IslandModuleID?) -> (moduleID: IslandModuleID, status: IslandStatus)? {
        var latest: (moduleID: IslandModuleID, entry: StatusEntry)?
        for id in statusEntries.keys.sorted() where id != moduleID {
            guard let top = visibleEntries(for: id).first, top.status.tone == .critical else { continue }
            if latest.map({ top.raiseOrder > $0.entry.raiseOrder }) ?? true {
                latest = (id, top)
            }
        }
        return latest.map { (moduleID: $0.moduleID, status: $0.entry.status) }
    }

    /// Modules call this through `ModuleMessenger.setStatus(_:)`.
    func setStatus(_ status: IslandStatus, from moduleID: IslandModuleID) {
        guard startedModules.contains(moduleID) else { return }
        var next = (statusEntries[moduleID] ?? [:]).values.map(\.status).filter { $0.key != status.key }
        next.append(status)
        replaceStatuses(next, for: moduleID)
    }

    /// Modules call this through `ModuleMessenger.clearStatus(_:)`.
    func clearStatus(_ key: String, from moduleID: IslandModuleID) {
        guard let entries = statusEntries[moduleID], entries[key] != nil else { return }
        replaceStatuses(entries.values.map(\.status).filter { $0.key != key }, for: moduleID)
    }

    /// Modules call this through `ModuleMessenger.setStatuses(_:)`.
    func setStatuses(_ statuses: [IslandStatus], from moduleID: IslandModuleID) {
        guard startedModules.contains(moduleID) else { return }
        replaceStatuses(statuses, for: moduleID)
    }

    /// Hides a dismissible status, and its notice, while the module keeps setting it.
    func dismissStatus(_ key: String, of moduleID: IslandModuleID) {
        guard var entry = statusEntries[moduleID]?[key], entry.status.isDismissible, !entry.isDismissed else { return }
        entry.isDismissed = true
        statusEntries[moduleID]?[key] = entry
        withdrawRaisedNotices(from: moduleID, statusKey: key)
    }

    private func visibleEntries(for moduleID: IslandModuleID) -> [StatusEntry] {
        (statusEntries[moduleID] ?? [:]).values
            .filter { !$0.isDismissed }
            .sorted { lhs, rhs in
                if lhs.status.tone != rhs.status.tone { return lhs.status.tone > rhs.status.tone }
                if lhs.status.level != rhs.status.level { return lhs.status.level > rhs.status.level }
                if lhs.raiseOrder != rhs.raiseOrder { return lhs.raiseOrder > rhs.raiseOrder }
                return lhs.status.key < rhs.status.key
            }
    }

    /// The one place statuses change. Writes only when something differs, then withdraws the
    /// notices of cleared statuses and announces raised ones.
    private func replaceStatuses(_ statuses: [IslandStatus], for moduleID: IslandModuleID) {
        let now = clock.now
        let old = statusEntries[moduleID] ?? [:]
        // The last status with a key wins; expired ones are dropped.
        var latest: [String: IslandStatus] = [:]
        var keys: [String] = []
        for status in statuses where !(status.expiresAt.map { $0 <= now } ?? false) {
            if latest.updateValue(status, forKey: status.key) == nil { keys.append(status.key) }
        }
        var entries: [String: StatusEntry] = [:]
        var raised: [StatusEntry] = []
        for key in keys {
            guard let status = latest[key] else { continue }
            var entry: StatusEntry
            if let previous = old[key] {
                entry = previous
                entry.status = status
                if Self.isRaise(of: status, from: previous.status) {
                    lastRaise &+= 1
                    entry.raiseOrder = lastRaise
                    raised.append(entry)
                }
            } else {
                lastRaise &+= 1
                entry = StatusEntry(status: status, raiseOrder: lastRaise)
                raised.append(entry)
            }
            entries[key] = entry
        }
        guard entries != old else { return }
        statusEntries[moduleID] = entries.isEmpty ? nil : entries
        scheduleStatusExpiry()
        for key in old.keys where entries[key] == nil {
            withdrawRaisedNotices(from: moduleID, statusKey: key)
        }
        for entry in raised where !entry.isDismissed {
            announceRaise(of: entry, from: moduleID)
        }
    }

    /// Worse than before: a higher tone, or the same tone at a higher level.
    static func isRaise(of status: IslandStatus, from previous: IslandStatus) -> Bool {
        status.tone > previous.tone || (status.tone == previous.tone && status.level > previous.level)
    }

    private func announceRaise(of entry: StatusEntry, from moduleID: IslandModuleID) {
        let status = entry.status
        guard status.tone >= .warning, status.announcesWhenRaised else { return }
        announcer.announce(AccessibilityAnnouncement(
            token: "status.\(moduleID.rawValue).\(status.key).\(entry.raiseOrder)",
            message: status.spokenText,
            priority: status.tone == .critical ? .high : .medium
        ))
        // The open panel already shows this module, so the pill would only repeat it.
        guard moduleID != shownModule else { return }
        let notice = IslandNotice(
            key: "status.\(status.key)",
            title: status.pillText,
            detail: status.detail == nil ? nil : status.spokenText,
            tone: status.tone == .critical ? .error : .warning,
            systemImage: status.systemImage
        )
        post(notice, from: moduleID, raisedStatusKey: status.key)
    }

    private func scheduleStatusExpiry() {
        statusExpiryTask?.cancel()
        statusExpiryTask = nil
        let deadlines = statusEntries.values.flatMap(\.values).compactMap(\.status.expiresAt)
        guard let deadline = deadlines.min() else { return }
        statusExpiryTask = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pruneExpiredStatuses()
        }
    }

    private func pruneExpiredStatuses() {
        statusExpiryTask = nil
        let now = clock.now
        for (moduleID, entries) in statusEntries
        where entries.values.contains(where: { $0.status.expiresAt.map { $0 <= now } ?? false }) {
            replaceStatuses(entries.values.map(\.status), for: moduleID)
        }
        scheduleStatusExpiry()
    }

    // MARK: - Shown module

    /// The presenter's view of the expanded panel: the module it shows (`nil` when the panel is
    /// not expanded) and whether other modules' notices wait for it to close (it is not pinned).
    /// Withdraws that module's raised-status notices, lets its notices go first, and keeps the
    /// handoff from cutting a notice short for one that could not appear anyway.
    func setShownModule(_ moduleID: IslandModuleID?, othersWait: Bool) {
        let othersWait = moduleID != nil && othersWait
        guard shownModule != moduleID || othersWaitForShownModule != othersWait else { return }
        shownModule = moduleID
        othersWaitForShownModule = othersWait
        if let moduleID { withdrawRaisedNotices(from: moduleID) }
        promoteShownModuleNotices()
        scheduleExpiry()
    }

    /// The presenter reports which notice the pill shows: the current notice's id while it is on
    /// screen, `nil` while it waits (for the panel to close, during a drag) or nothing can show it.
    /// Once a notice has appeared it follows the panel without waiting again, so a shown
    /// module's notice no longer goes ahead of it.
    func setVisibleNotice(_ id: UInt64?) {
        if let id { appearedNoticeID = id }
        if visibleNoticeID != id { visibleNoticeID = id }
    }

    /// The current notice while the pill shows it. A notice that waits is not on screen, so
    /// the notch keeps showing statuses (or the drag arrow) until it appears.
    var visibleNotice: PostedNotice? {
        guard let current = currentNotice, current.id == visibleNoticeID else { return nil }
        return current
    }

    private var currentHasAppeared: Bool {
        currentNotice.map { $0.id == appearedNoticeID } ?? false
    }

    /// Whether the notice could appear now, rather than wait for the panel to close.
    private func isReady(_ posted: PostedNotice) -> Bool {
        !othersWaitForShownModule || posted.moduleID == shownModule
    }

    private var hasReadyWaitingNotice: Bool {
        waitingNotices.contains(where: isReady)
    }

    /// While an unpinned panel shows a module, its notices go ahead of the ones that wait for
    /// the panel to close, including a current notice that has not appeared.
    private func promoteShownModuleNotices() {
        guard othersWaitForShownModule, let shown = shownModule else { return }
        let mine = waitingNotices.filter { $0.moduleID == shown }
        guard !mine.isEmpty else { return }
        var others = waitingNotices.filter { $0.moduleID != shown }
        if let current = currentNotice, current.moduleID != shown, !currentHasAppeared {
            others.insert(current, at: 0)
            waitingNotices = Array(mine.dropFirst()) + others
            show(mine[0])
        } else if waitingNotices != mine + others {
            waitingNotices = mine + others
        }
    }

    // MARK: - Posting

    /// Modules call this through `ModuleMessenger.post(_:)`. The notice is spoken now, even if
    /// it has to wait to be seen.
    func post(_ notice: IslandNotice, from moduleID: IslandModuleID) {
        post(notice, from: moduleID, raisedStatusKey: nil)
    }

    /// A raised status's notice is not spoken here: `announceRaise` already spoke it, also
    /// when no notice is queued.
    private func post(_ notice: IslandNotice, from moduleID: IslandModuleID, raisedStatusKey: String?) {
        let speaks = raisedStatusKey == nil
        lastRevision &+= 1
        let revision = lastRevision
        moduleRevisions[moduleID] = revision

        if let current = currentNotice, current.moduleID == moduleID, current.notice.key == notice.key {
            let replacement = PostedNotice(id: current.id, revision: revision, moduleID: moduleID,
                                           notice: notice, raisedStatusKey: raisedStatusKey)
            if speaks { announceIfChanged(from: current, to: replacement) }
            currentNotice = replacement
            // With nothing ready waiting it gets its full time again. Otherwise it keeps its
            // visible time, so reposting cannot hold the pill past the handoff.
            if hasReadyWaitingNotice { scheduleExpiry() } else { restartVisibleTime() }
            return
        }
        if let index = waitingNotices.firstIndex(where: { $0.moduleID == moduleID && $0.notice.key == notice.key }) {
            let waiting = waitingNotices[index]
            let replacement = PostedNotice(id: waiting.id, revision: revision, moduleID: moduleID,
                                           notice: notice, raisedStatusKey: raisedStatusKey)
            if speaks { announceIfChanged(from: waiting, to: replacement) }
            waitingNotices[index] = replacement
            return
        }

        lastID &+= 1
        let posted = PostedNotice(id: lastID, revision: revision, moduleID: moduleID,
                                  notice: notice, raisedStatusKey: raisedStatusKey)
        if speaks { announcer.announce(AccessibilityAnnouncementPlanner.announcement(for: posted)) }
        guard let current = currentNotice else {
            show(posted)
            return
        }
        if !hasReadyWaitingNotice, current.moduleID == moduleID, current.isPlain, posted.isPlain {
            show(posted)
            return
        }
        enqueue(posted)
        promoteShownModuleNotices()
    }

    /// Modules call this through `ModuleMessenger.withdrawNotice(_:)`. Removes the module's
    /// visible or waiting notice with this key.
    func withdrawNotice(_ key: String, from moduleID: IslandModuleID) {
        withdrawNotices { $0.moduleID == moduleID && $0.notice.key == key }
    }

    /// Withdraws the module's notices for raised statuses: all of them, or the one for `statusKey`.
    private func withdrawRaisedNotices(from moduleID: IslandModuleID, statusKey: String? = nil) {
        withdrawNotices { posted in
            guard posted.moduleID == moduleID, let key = posted.raisedStatusKey else { return false }
            return statusKey == nil || key == statusKey
        }
    }

    private func withdrawNotices(where matches: (PostedNotice) -> Bool) {
        let count = waitingNotices.count
        if waitingNotices.contains(where: matches) {
            waitingNotices.removeAll(where: matches)
        }
        if let current = currentNotice, matches(current) {
            showNext()
        } else if waitingNotices.count != count {
            scheduleExpiry()
        }
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

    /// Visible time the current notice may still use, given the queue. The handoff applies
    /// only when a waiting notice could appear in its place.
    private func remainingTime(at now: Duration) -> Duration? {
        guard let current = currentNotice else { return nil }
        var limit = Self.duration(for: current.notice)
        if hasReadyWaitingNotice { limit = min(limit, Self.handoffDuration) }
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
