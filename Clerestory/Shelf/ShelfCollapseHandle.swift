import SwiftUI

/// The title-bar collapse button and the transparent edge hit area share an action through an
/// EnvironmentKey. The default nil still renders the button in previews and unit tests, but gives it no
/// action.
private struct ShelfHideActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    /// Collapse action; injected by ShelfWindowController on the panel content root.
    var shelfHideAction: (@MainActor () -> Void)? {
        get { self[ShelfHideActionEnvironmentKey.self] }
        set { self[ShelfHideActionEnvironmentKey.self] = newValue }
    }
}
