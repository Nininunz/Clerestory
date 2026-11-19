import Foundation
@testable import Clerestory

/// A message clock that moves only when a test advances it, so notice timing is deterministic.
///
/// Time is an exact `Duration`, and `advance(by:)` with seconds rounds to whole milliseconds, so
/// steps such as 0.3 + 0.3 + 0.4 land exactly on a 1 s deadline.
final class ManualMessageClock: MessageClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    // Guards every stored property below.
    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleepers: Set<UUID> = []
    /// Sleepers that `advance(by:)` resumed and that have not returned to their caller yet.
    private var wokenSleepers: Set<UUID> = []

    var now: Duration { lock.withLock { current } }

    @MainActor
    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        // Both helpers inherit the main actor, so a woken sleeper resumes straight on it.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledSleepers.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if current >= deadline {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelledSleepers.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
        // The caller runs on from here in the same main-actor job, so once this is gone the
        // caller's work after the sleep is done.
        _ = lock.withLock { wokenSleepers.remove(id) }
    }

    /// Moves time forward by whole milliseconds, wakes every sleeper that is due and waits
    /// until each has run.
    @MainActor
    func advance(by seconds: TimeInterval) async {
        await advance(by: .milliseconds(Int64((seconds * 1000).rounded())))
    }

    @MainActor
    func advance(by duration: Duration) async {
        let due: [Sleeper] = lock.withLock {
            current += duration
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys {
                sleepers[id] = nil
                wokenSleepers.insert(id)
            }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
        await settle()
    }

    /// Waits until every woken sleeper has returned, then lets other main-actor work that is
    /// already scheduled run, without moving time.
    @MainActor
    func settle() async {
        var spins = 0
        while lock.withLock({ !wokenSleepers.isEmpty }) {
            spins += 1
            precondition(spins < 10_000, "A woken message-clock sleeper never resumed")
            await Task.yield()
        }
        for _ in 0..<10 { await Task.yield() }
    }
}

extension AccessibilityAnnouncementCenter {
    /// An announcer that records what it would speak instead of posting to the system.
    @MainActor
    static func recording(into recorder: AnnouncementRecorder) -> AccessibilityAnnouncementCenter {
        AccessibilityAnnouncementCenter { recorder.announcements.append($0) }
    }
}

@MainActor
final class AnnouncementRecorder {
    var announcements: [AccessibilityAnnouncement] = []
    var messages: [String] { announcements.map(\.message) }
}

extension IslandMessageCenter {
    /// A center for tests: time only moves when the test advances `clock`, and nothing reaches
    /// the system announcer. Pass `.recording(into:)` to assert what would be spoken.
    @MainActor
    static func forTesting(
        clock: ManualMessageClock = ManualMessageClock(),
        announcer: AccessibilityAnnouncementCenter = AccessibilityAnnouncementCenter { _ in }
    ) -> IslandMessageCenter {
        IslandMessageCenter(clock: clock, announcer: announcer)
    }
}
