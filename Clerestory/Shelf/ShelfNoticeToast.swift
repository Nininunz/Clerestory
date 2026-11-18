import SwiftUI

/// Shared pill used by the detached Island notice panel and preview host.
struct ShelfNoticeToast: View {
    let notice: ShelfNoticeContent
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.system(size: 11, weight: .regular))
                .fontWeight(.regular)
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = notice.recoveryAction, let onPerformRecovery {
                Button("Recovery") { onPerformRecovery(action) }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .buttonStyle(.plain)
                    .help("Open Storage recovery")
                    .accessibilityIdentifier("shelf.notice.recovery")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: ShelfNoticePlacement.width)
        .background(Color.black, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: ShelfNoticePlacement.shadowRadius,
                y: ShelfNoticePlacement.shadowOffsetY)
        .help(notice.details ?? notice.message)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(notice.details ?? notice.message))
        .accessibilityIdentifier("shelf.notice")
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning, .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .success: .green.opacity(0.85)
        case .info: .white.opacity(0.65)
        case .warning: .orange
        case .error: .red.opacity(0.9)
        }
    }
}

/// The hosted panel measures and renders this same hierarchy.
struct ShelfNoticePanelContent: View {
    let notice: ShelfNoticeContent
    let onRecovery: (RecoveryAction) -> Void

    var body: some View {
        ShelfNoticeToast(notice: notice, onPerformRecovery: onRecovery)
            .frame(width: ShelfNoticePlacement.width)
            .fixedSize(horizontal: false, vertical: true)
            .padding(ShelfNoticePlacement.shadowInset)
            .environment(\.colorScheme, .dark)
    }
}
