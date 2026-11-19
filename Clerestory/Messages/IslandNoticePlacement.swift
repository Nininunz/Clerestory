import AppKit
import SwiftUI

/// Screen-space placement is independent of the Island's content and hitbox.
enum IslandNoticePlacement {
    static let gap: CGFloat = 10
    static let shadowRadius: CGFloat = 8
    static let shadowOffsetY: CGFloat = 3
    // Let the blur fade to transparent before reaching the window's crop boundary.
    static let shadowInset: CGFloat = shadowRadius * 3 + shadowOffsetY
    static let width: CGFloat = 300

    static func frame(below island: CGRect, pillSize: CGSize) -> CGRect {
        CGRect(x: island.midX - pillSize.width / 2 - shadowInset,
               y: island.minY - gap - pillSize.height - shadowInset,
               width: pillSize.width + shadowInset * 2,
               height: pillSize.height + shadowInset * 2)
    }

    static func pillSize(in windowSize: CGSize) -> CGSize {
        CGSize(width: windowSize.width - shadowInset * 2,
               height: windowSize.height - shadowInset * 2)
    }

    /// Used by static preview hosts; the live panel caches its own measurement.
    @MainActor
    static func pillSize(for notice: IslandNotice) -> CGSize {
        let view = NSHostingView(rootView: IslandNoticePanelContent(notice: notice, onAction: { _ in }))
        return pillSize(in: view.fittingSize)
    }
}
