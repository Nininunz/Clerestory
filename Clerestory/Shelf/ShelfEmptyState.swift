import SwiftUI

/// Center the illustration, drop instructions, and shortcut hint within a translucent dashed border.
///
/// Dashed border implies the drop area; when S4 is dragged over, the ShelfView's drop point highlight
/// (`DropTargetState.isTargeted`) takes over the emphasis state. Text is in Localizable.xcstrings (S10);
/// D9: merged into a single accessible element, VoiceOver reads the hint and shortcut in one go.
struct ShelfEmptyState: View {
    /// The panel shortcut as shown in Settings, or nil when it is off or unset.
    var shortcut: String?

    var body: some View {
        VStack(spacing: 12) {
            // Same font as the screen edge pull ring, implying that it 'stays there after collapsing'
            // (issue #10).
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("Drop files here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // F-05: Dual-mode drag-in hint (direct drag-in = reference; ⌘ drag-in = move into original
                // file).
                Text("Hold ⌘ while dropping to move the original here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let shortcut {
                    Text("Press \(shortcut) to show or hide the shelf")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shelf.emptyState")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        // issue #10: lighter continuous rounded corner dashed frame + very light background color,
        // blending into glass rather than sitting on top.
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(0.13),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 5])
                )
        }
        .padding(8)
    }
}

// MARK: - Previews

#Preview("Empty state") {
    ShelfEmptyState(shortcut: "⌘⇧Space")
        .frame(width: 280, height: 400)
}
