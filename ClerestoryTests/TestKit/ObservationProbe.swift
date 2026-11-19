import Foundation
import Observation

/// Counts every change to the observable state read in `track(_:)`. `withObservationTracking`
/// reports one change and then stops observing, so the probe observes again from inside
/// `onChange`, which runs synchronously before each change. Two writes therefore count as two
/// changes, as SwiftUI would see two invalidations. Main-actor state only, like the message
/// center.
@MainActor
final class ObservationProbe {
    private(set) var changes = 0
    private var read: (@MainActor () -> Void)?

    func track(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        observe()
    }

    private func observe() {
        guard let read else { return }
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                self?.changes += 1
                self?.observe()
            }
        }
    }
}
