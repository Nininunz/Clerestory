import SwiftUI

/// Supplied by the module host only when a module opts into content-sized extension.
struct IslandModuleExtensionContext {
    var isExtended: Binding<Bool>
    var reportHeight: (CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var islandModuleExtension: IslandModuleExtensionContext? = nil
    @Entry var islandSurfaceHeight: CGFloat? = nil
}

struct IslandModuleExtendButton: View {
    @Environment(\.islandModuleExtension) private var extensionContext

    var body: some View {
        if let context = extensionContext {
            Button { context.isExtended.wrappedValue.toggle() } label: {
                Image(systemName: context.isExtended.wrappedValue
                      ? "arrow.up.right.and.arrow.down.left" : "arrow.down.left.and.arrow.up.right")
            }
            .buttonStyle(IslandHeaderButtonStyle())
            .help(context.isExtended.wrappedValue ? "Use regular height" : "Extend to fit content")
            .accessibilityLabel(Text(context.isExtended.wrappedValue ? "Use regular height" : "Extend module"))
        }
    }
}

struct IslandModuleExtendToggle: View {
    @Environment(\.islandModuleExtension) private var extensionContext

    var body: some View {
        if let context = extensionContext {
            Toggle("Extended Height", isOn: context.isExtended)
                .toggleStyle(IslandClipboardToggleStyle())
                .font(.system(size: 11, weight: .medium))
        }
    }
}

/// A bounded body viewport. Keep the module header outside this scroll view.
struct IslandModuleScrollView<Content: View>: View {
    @Environment(\.islandSurfaceHeight) private var surfaceHeight
    @Environment(\.islandModuleExtension) private var extensionContext
    var fillsViewport = false
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        // Measure before fillsViewport adds artificial empty space.
                        ceil(geometry.size.height + 2
                             + (surfaceHeight ?? 0) - viewport.size.height)
                    } action: { height in
                        if surfaceHeight != nil { extensionContext?.reportHeight(height) }
                    }
                    // A short module can use the entire viewport while longer
                    // content still scrolls. Include the inset in that height
                    // so fitting content does not acquire a tiny scroll range.
                    .frame(minHeight: fillsViewport ? max(0, viewport.size.height - 2) : nil,
                           alignment: .top)
                    .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct IslandSelectedAccessibilityModifier: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

enum IslandVisualStyle {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.46)
    static let controlFill = Color.white.opacity(0.09)
    static let selectedFill = Color.accentColor.opacity(0.22)
    static let cardFill = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
}

/// Feedback changes appearance without moving content or changing hit targets.
struct IslandPressFeedbackStyle: ButtonStyle {
    var reduceMotion = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(IslandControlFeedback(isPressed: configuration.isPressed, cornerRadius: cornerRadius, reduceMotion: reduceMotion))
    }
}

private struct IslandControlFeedback: ViewModifier {
    let isPressed: Bool
    var cornerRadius: CGFloat = 6
    var reduceMotion = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(isEnabled && isHovered ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(isEnabled && isFocused ? 0.9 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? (isPressed ? 0.72 : 1) : 0.35)
            .onHover { isHovered = $0 }
            .animation(reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
    }
}

struct IslandActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : IslandVisualStyle.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Capsule().fill(prominent ? Color.white.opacity(0.92) : Color.white.opacity(0.10)))
            .contentShape(Capsule())
            .modifier(IslandControlFeedback(isPressed: configuration.isPressed, cornerRadius: 14))
    }
}

struct IslandProgressTrack: View {
    let progress: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(min(max(progress, 0), 1) * 100)) percent"))
    }
}

enum IslandModuleLayout {
    static let headerHeight: CGFloat = 34
    static let headerSpacing: CGFloat = 10
}

struct IslandModuleHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let systemImage: String
    private let actions: Actions
    private let showsExtendButton: Bool

    init(title: LocalizedStringKey, subtitle: String?, systemImage: String,
         showsExtendButton: Bool = true,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
        self.showsExtendButton = showsExtendButton
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                actions
                if showsExtendButton { IslandModuleExtendButton() }
            }
                .fixedSize()
        }
        .frame(height: IslandModuleLayout.headerHeight)
    }
}

extension IslandModuleHeader where Actions == EmptyView {
    init(title: LocalizedStringKey, subtitle: String?, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

/// Shared treatment for ordinary module-header actions (not segmented controls).
struct IslandHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IslandVisualStyle.primaryText)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Circle())
            .modifier(IslandControlFeedback(isPressed: configuration.isPressed, cornerRadius: 14))
    }
}

/// Full-body states share typography, spacing, and optional recovery actions.
struct IslandModuleState<Actions: View>: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    var systemImage = "exclamationmark.triangle"
    var isLoading = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text(title))
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IslandVisualStyle.primaryText)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
            HStack(spacing: 8) { actions }
                .buttonStyle(IslandActionButtonStyle())
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IslandLoadingState: View {
    let title: LocalizedStringKey
    var body: some View {
        IslandModuleState(title: title, isLoading: true) { EmptyView() }
    }
}

struct IslandEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        IslandModuleState(title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

/// Non-blocking notices preserve usable content and fixed search controls.
struct IslandModuleNotice: View {
    let message: String
    var isError = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : IslandVisualStyle.secondaryText)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(IslandHeaderButtonStyle())
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(IslandVisualStyle.cardFill))
    }
}

/// A focus-independent toggle for the dark, non-activating Island panel.
/// AppKit's native switch dims its tint when the panel loses key-window focus,
/// which makes an enabled control look disabled. Keeping the visual state in
/// SwiftUI leaves the Toggle's semantics and binding intact while making the
/// enabled/disabled distinction explicit.
struct IslandClipboardToggleStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                if showsLabel { configuration.label }
                Capsule(style: .continuous)
                    .fill(configuration.isOn
                          ? Color.accentColor
                          : Color.white.opacity(0.16))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.96))
                            .frame(width: 26, height: 18)
                            .padding(2)
                    }
                    .frame(width: 44, height: 22)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}

/// The live Island and module previews share the same visible edge and insets.
struct IslandExpandedSurface<Navigation: View, Content: View>: View {
    let hasPhysicalNotch: Bool
    @ViewBuilder var navigation: Navigation
    @ViewBuilder var content: Content

    static var visiblePadding: CGFloat { 14 }

    var body: some View {
        let shape = IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 26)
        VStack(spacing: 10) {
            navigation
            content
                .clipped()
                .padding(.horizontal, IslandExpandedLayout.horizontalInset(hasPhysicalNotch: hasPhysicalNotch))
                .padding(.bottom, Self.visiblePadding)
        }
        .contentShape(shape)
        .background {
            ZStack {
                Color.black
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
            }
            .clipShape(shape)
        }
        .overlay {
            if !hasPhysicalNotch {
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
    }
}

enum IslandExpandedLayout {
    static func horizontalInset(hasPhysicalNotch: Bool) -> CGFloat {
        14 + (hasPhysicalNotch ? IslandSurfaceShape.bodyInset(cornerRadius: 26) : 0)
    }

    static func contentWidth(surfaceWidth: CGFloat, hasPhysicalNotch: Bool) -> CGFloat {
        max(1, surfaceWidth - 2 * horizontalInset(hasPhysicalNotch: hasPhysicalNotch))
    }
}

struct IslandSurfaceShape: InsettableShape {
    var attachedToScreenTop: Bool
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    static func bodyInset(cornerRadius: CGFloat) -> CGFloat {
        min(7, max(4, cornerRadius * 0.45))
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard attachedToScreenTop else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        let bottomRadius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topCut = Self.bodyInset(cornerRadius: bottomRadius)
        let leftBody = rect.minX + topCut
        let rightBody = rect.maxX - topCut
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: leftBody, y: rect.minY + topCut),
            control1: CGPoint(x: rect.minX + topCut * 0.55, y: rect.minY),
            control2: CGPoint(x: leftBody, y: rect.minY + topCut * 0.45)
        )
        path.addLine(to: CGPoint(x: leftBody, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rightBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: rect.minY + topCut))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rightBody, y: rect.minY + topCut * 0.45),
            control2: CGPoint(x: rect.maxX - topCut * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
