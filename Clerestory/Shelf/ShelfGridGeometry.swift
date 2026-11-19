import Foundation

/// S10: shelf grid geometry shared model —— frame of top-level card in window content coordinate system
/// (SwiftUI `.global`, top-left origin), including scroll offset. Reported in real-time by `ShelfView`
/// grid cell via `onGeometryChange`; drag-and-insert positioning (C6, `DragContainerView` →
/// `DropInsertionLocator`) uses this data.
@MainActor
@Observable
final class ShelfGridGeometry {
    /// Card frame indexed by top-level item id. Stack overlay items do not report (do not participate in
    /// grid positioning).
    var cardFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var frameOwners: [UUID: UUID] = [:]

    func report(_ frame: CGRect, for itemID: UUID, owner: UUID) {
        frameOwners[itemID] = owner
        cardFrames[itemID] = frame
    }

    func removeFrame(for itemID: UUID, owner: UUID) {
        guard frameOwners[itemID] == owner else { return }
        frameOwners.removeValue(forKey: itemID)
        cardFrames.removeValue(forKey: itemID)
    }
}

/// C6: drag-in mouse position → pure logic mapping of grid insertion index (decoupled from AppKit/SwiftUI,
/// testable with unit tests).
///
/// Input is (items array index, card frame) list and mouse point (same coordinate system). Adaptive grid
/// layout by row (same minY within a row), and within a row sorted by x —— i.e., reading order matches
/// items order.
enum DropInsertionLocator {
    /// Row territory vertical expansion/down extension `rowGapSlack`: row gap ownership belongs to the
    /// upper row; space above the first row (e.g., title bar area) and below the last row (grid blank
    /// area) does not match any row → append to end.
    nonisolated static let rowGapSlack: CGFloat = 6

    /// Calculate insertion index (0...itemCount; itemCount = append to end).
    ///
    /// Row territory vertical expansion/down extension `rowGapSlack`: row gap ownership belongs to the
    /// upper row; space above the first row (e.g., title bar area) and below the last row (grid blank
    /// area) does not match any row → append to end. Within a row, take the first activated card to the
    /// right of the point; if the point is to the right of the last card in the row → append after the end
    /// of the row (start of the next row; end of the last row is itemCount). If no geometry is available
    /// (layout not reported yet), fall back to append to end (S4 existing behavior).
    ///
    /// `activation` decides which line inside a card the dragged point has to
    /// cross before the slot moves in front of it:
    /// - `.center` follows the card's horizontal middle. Vertical drags and
    ///   external imports use it, so the slot follows the column under the
    ///   pointer instead of the horizontal edge the card came from.
    /// - `.leading` / `.trailing` measure `activationRatio` inward from that
    ///   edge. Horizontal Shelf reordering uses them so both directions swap
    ///   as soon as the dragged card barely enters the next one.
    nonisolated enum Activation: Sendable {
        case center
        case leading
        case trailing
    }

    nonisolated static func insertionIndex(for point: CGPoint,
                                           frames: [(index: Int, frame: CGRect)],
                                           itemCount: Int,
                                           activation: Activation = .center,
                                           activationRatio: CGFloat = 0.10) -> Int {
        guard itemCount > 0 else { return 0 }
        let ratio = min(max(activationRatio, 0), 1)
        let sorted = frames.sorted { $0.index < $1.index }
        guard !sorted.isEmpty else { return itemCount }

        // Row grouping: cards in the same row have vertically aligned centers. Card heights can differ
        // when a title wraps, so minY would split one visual row into overlapping pseudo-rows.
        var rows: [[(index: Int, frame: CGRect)]] = []
        for entry in sorted {
            if let rowMidY = rows.last?.first?.frame.midY,
               abs(entry.frame.midY - rowMidY) <= 4 {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }

        for row in rows {
            let rowTop = (row.map(\.frame.minY).min() ?? 0) - rowGapSlack
            let rowBottom = (row.map(\.frame.maxY).max() ?? 0) + rowGapSlack
            guard point.y >= rowTop, point.y <= rowBottom else { continue }
            for entry in row {
                let activationX: CGFloat
                switch activation {
                case .center:
                    activationX = entry.frame.midX
                case .leading:
                    activationX = entry.frame.minX + entry.frame.width * ratio
                case .trailing:
                    activationX = entry.frame.maxX - entry.frame.width * ratio
                }
                guard point.x < activationX else { continue }
                return entry.index
            }
            let lastIndex = row.map(\.index).max() ?? (itemCount - 1)
            return min(lastIndex + 1, itemCount)
        }
        return itemCount
    }
}
