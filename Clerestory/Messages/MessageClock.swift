import Foundation

/// The time source for notice lifetimes. Tests inject a manual clock so timing is deterministic.
///
/// Time is a `Duration` since an arbitrary origin on a monotonic timeline, so changes to the
/// wall clock never stretch or cut short a notice, and sums of visible time stay exact.
protocol MessageClock: Sendable {
    var now: Duration { get }
    /// Returns once `now` reaches `deadline`. Throws `CancellationError` when the task is cancelled.
    /// Main-actor isolated so the caller never hops off the main actor while it waits.
    @MainActor func sleep(until deadline: Duration) async throws
}

/// Time for the running app. It uses the suspending clock: a notice is not visible while the
/// Mac sleeps, so that time does not count.
struct SystemMessageClock: MessageClock {
    private let origin = SuspendingClock.now

    var now: Duration { origin.duration(to: .now) }

    @MainActor
    func sleep(until deadline: Duration) async throws {
        try await Task.sleep(until: origin.advanced(by: deadline), clock: .suspending)
    }
}
