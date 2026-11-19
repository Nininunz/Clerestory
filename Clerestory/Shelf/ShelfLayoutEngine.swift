import Foundation

/// Column math for the Shelf's card grid, shared by the SwiftUI grid and keyboard navigation so
/// both agree on how many cards fit in a row.
enum ShelfLayoutEngine {
    /// Grid column minimum width and spacing, matching `ShelfView.gridSpacing`.
    static let gridColumnMinimum: CGFloat = 84
    static let gridSpacing: CGFloat = 12
    /// Horizontal padding around the grid inside an expanded stack.
    static let contentPadding: CGFloat = 32

    /// Column count for a panel width, after the fixed padding (n columns need
    /// n×min + (n-1)×spacing ≤ available width).
    static func columnCount(forPanelWidth width: CGFloat) -> Int {
        gridColumnCount(for: width - contentPadding)
    }

    /// Column count for a grid viewport that is already inside the padding.
    ///
    /// SwiftUI's `adaptive` grid re-derives this from its own width, and the
    /// scrolling container is a little narrower than the plain grid, so the
    /// same shelf switched from three columns to two once it started
    /// scrolling. Deriving the count here keeps both states identical.
    static func gridColumnCount(for gridWidth: CGFloat) -> Int {
        max(1, Int((gridWidth + gridSpacing) / (gridColumnMinimum + gridSpacing)))
    }
}
