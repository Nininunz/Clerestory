import SwiftUI

/// The notice pill: the only text surface for notices, used by the detached notice panel and
/// the preview host.
struct IslandNoticePill: View {
    let notice: IslandNotice
    var onPerformAction: ((IslandNoticeAction) -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(notice.title)
                .font(.system(size: 11, weight: .regular))
                .fontWeight(.regular)
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = notice.action, let onPerformAction, let actionTitle {
                Button(actionTitle) { onPerformAction(action) }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .buttonStyle(.plain)
                    .help(action.help)
                    .accessibilityIdentifier("island.notice.action")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: IslandNoticePlacement.width)
        .background(Color.black, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: IslandNoticePlacement.shadowRadius,
                y: IslandNoticePlacement.shadowOffsetY)
        .help(notice.fullText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(notice.fullText))
        .accessibilityIdentifier("island.notice")
    }

    /// The button's title, from the notice's action. `nil` when the pill shows no button.
    var actionTitle: String? {
        onPerformAction == nil ? nil : notice.action?.title
    }

    private var tint: Color {
        switch notice.tone {
        case .success: .green.opacity(0.85)
        case .info: .white.opacity(0.65)
        case .warning: .orange
        case .error: .red.opacity(0.9)
        }
    }
}

/// The hosted panel measures and renders this same hierarchy.
struct IslandNoticePanelContent: View {
    let notice: IslandNotice
    let onAction: (IslandNoticeAction) -> Void

    var body: some View {
        IslandNoticePill(notice: notice, onPerformAction: onAction)
            .frame(width: IslandNoticePlacement.width)
            .fixedSize(horizontal: false, vertical: true)
            .padding(IslandNoticePlacement.shadowInset)
            .environment(\.colorScheme, .dark)
    }
}
