import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Presentation-only text; copying and exporting still use the original snippet.
enum ShelfTextDocumentPreview {
    static func body(for item: ShelfItem) -> String {
        item.text ?? ""
    }
}

private struct ShelfThumbnailBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Visible, non-color-only card state. Completed transfers deliberately resolve
/// to nil so the normal ready card remains quiet.
enum ShelfCardVisualStatus: Equatable {
    case receiving
    case delivering
    case destinationAccepted
    case deliveryFailed
    case managedCopy

    static func resolve(item: ShelfItem,
                        transferStatus: TransferItemAccessibilityStatus?) -> Self? {
        switch transferStatus {
        case .receiving: return .receiving
        case .delivering: return .delivering
        case .destinationAccepted: return .destinationAccepted
        case .deliveryFailed: return .deliveryFailed
        case .added, .delivered: break
        case nil: break
        }
        return item.isCut ? .managedCopy : nil
    }

    var title: String {
        switch self {
        case .receiving: String(localized: "Receiving…")
        case .delivering: String(localized: "Delivering…")
        case .destinationAccepted: String(localized: "Destination accepted")
        case .deliveryFailed: String(localized: "Not delivered")
        case .managedCopy: String(localized: "Managed copy · Original in Trash")
        }
    }

    var symbolName: String {
        switch self {
        case .receiving: "arrow.down.circle"
        case .delivering: "arrow.up.circle"
        case .destinationAccepted: "checkmark.circle"
        case .deliveryFailed: "exclamationmark.triangle.fill"
        case .managedCopy: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .receiving, .delivering, .destinationAccepted: .secondary
        case .deliveryFailed: .red
        case .managedCopy: .orange
        }
    }
}

/// Single item card (12pt rounded corners, thumbnail area, two-line name, semantic state + source app
/// small icon).
///
/// Thumbnail strategy: file/folder/image asynchronously use `QLThumbnailGenerator` for real thumbnails;
/// fallback to `NSWorkspace.icon(forFile:)` on failure or loading; text shows text snippet preview; url
/// shows SF Symbol link placeholder. `isStale` (bookmark invalid) items are dimmed overall, and an
/// exclamation mark badge is overlaid in the top-left corner.
///
/// The context menu offers Quick Look, Open, and Show in Finder where the item kind and availability
/// allow. Stale items show File Unavailable. The caller supplies the removal action through
/// `ShelfStore.remove(ids:)`. Double-click opens Quick Look.
///
/// Drag Out (S5): Card covers `CardDragSourceBridge` (NSViewRepresentable) as mouse event authority ——
/// `mouseDragged` exceeding threshold starts `NSDraggingSession` (per §2.1 decision not using SwiftUI
/// onDrag), `mouseUp` without drag returns to click (single click selects and makes panel key to connect
/// space/Delete/Esc keyboard chain; clickCount ≥ 2 triggers Quick Look). Drag content and batch semantics
/// are determined by `dragContentsProvider` (injected by parent view), actual session is initiated by
/// `DragOutController` in environment.
struct ShelfItemCard: View {
    /// Displayed item.
    let item: ShelfItem
    /// Selected state (§3: accent color stroke + light fill).
    let isSelected: Bool
    /// Keyboard focus is independent from multi-selection and gets its own ring.
    let isKeyboardFocused: Bool
    /// Click callback; additive being true means ⌘ click (toggle selection), otherwise single select.
    let onSelect: (_ additive: Bool) -> Void
    /// "Remove from Shelf". Also drives right-click menu remove item and UX4 hover ✕ button; nil when both
    /// are not shown (removal semantics are injected by parent view).
    var onRemove: (() -> Void)?
    /// v1.2: safe recovery action selected by the parent (external reconnect,
    /// managed storage, or review a stack's unavailable children).
    var onRecover: (() -> Void)?
    /// One-shot copy action, exposed in the context menu and accessibility rotor.
    var onCopy: (() -> Void)?
    /// Runtime-only import/export state appended to the VoiceOver label.
    var transferStatus: TransferItemAccessibilityStatus?
    /// Item that determines thumbnail content; default is same as `item`. Stack card passes the first
    /// file-like child item.
    var thumbnailItem: ShelfItem?
    /// S5 drag-out content calculation: given the dragged card item, returns the set of items dragged this
    /// time and the top-level id involved (multi-select batch / stack semantics are determined by parent
    /// view). nil when dragging single card item.
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    /// QL / Workspace thumbnail (already synthesized SwiftUI Image, Sendable, safe for cross-task
    /// passing).
    @State private var thumbnail: ShelfThumbnail?
    /// Source app icon (parsed via LaunchServices by `sourceApp.bundleID`).
    @State private var sourceAppIcon: NSImage?
    /// UX4: Card hover state (drives fade-in/fade-out of top-right ✕ remove button).
    @State private var isHovering = false
    /// S4: Thumbnail loading via bookmark resolves file access rights (see `ThumbnailLoader`).
    @Environment(\.bookmarkService) private var bookmarkService
    /// S5 drag-out controller; nil (Preview/Unit Test) when drag is disabled, click unaffected.
    @Environment(\.dragOutController) private var dragOutController
    /// S6: Quick Look session; nil (Preview/Unit Test) when QL entry is disabled.
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    /// S6: text item open/location requires writing temporary .txt (see `ItemActions`).
    @Environment(\.tempFileService) private var tempFileService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.shelfSelectionMode) private var selectionMode

    private var cardCornerRadius: CGFloat { Self.cornerRadius }

    static let cornerRadius: CGFloat = 12
    /// Thumbnail area height (points).
    private let previewHeight: CGFloat = 76

    init(item: ShelfItem,
         isSelected: Bool,
         isKeyboardFocused: Bool = false,
         onSelect: @escaping (_ additive: Bool) -> Void,
         onRemove: (() -> Void)? = nil,
         onRecover: (() -> Void)? = nil,
         onCopy: (() -> Void)? = nil,
         transferStatus: TransferItemAccessibilityStatus? = nil,
         thumbnailItem: ShelfItem? = nil,
         dragContentsProvider: ((ShelfItem) -> DragOutContents)? = nil) {
        self.item = item
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onRecover = onRecover
        self.onCopy = onCopy
        self.transferStatus = transferStatus
        self.thumbnailItem = thumbnailItem
        self.dragContentsProvider = dragContentsProvider
    }

    var body: some View {
        VStack(spacing: 5) {
            if item.availability == .available {
                thumbnailArea
                    .overlay(alignment: .bottomTrailing) {
                        if let status = ShelfCardVisualStatus.resolve(item: item, transferStatus: transferStatus) {
                            Image(systemName: status.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(status.tint)
                                .padding(5)
                                .background(.black.opacity(0.85), in: Circle())
                                .help(status.title)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("shelf.item.\(item.id.uuidString).status")
                        }
                    }
            } else {
                availabilityArea
            }
            nameRow
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.white.opacity(0.90))
        .background { surface }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .overlay { keyboardFocusRing }
        .overlay(alignment: selectionMode ? .topTrailing : .topLeading) { selectionBadge }
        // A transparent NSView covers the card and handles left-button events. It records
        // mouse-down and starts a drag once movement crosses the threshold. Without a drag,
        // mouse-up selects the card or opens Quick Look on double-click. SwiftUI still handles
        // right-click and scrolling.
        .overlay {
            CardDragSourceBridge(
                itemID: item.id,
                onClick: { additive in activateCard(additive: additive) },
                onDoubleClick: {
                    guard !selectionMode, item.availability == .available else { return }
                    quickLookCoordinator?.toggle(contextItem: item)
                },
                onDragBegin: { sourceView, event in
                    guard item.availability == .available, let dragOutController else { return }
                    let contents = dragContentsProvider?(item)
                        ?? DragOutContents(items: [item], topLevelIDs: [item.id])
                    dragOutController.beginDrag(contents: contents,
                                                originatingItemID: item.id,
                                                from: sourceView,
                                                event: event)
                }
            )
        }
        // UX4: Hover ✕ Remove button. The z-order is above the drag-out event layer —— hit testing reaches
        // SwiftUI Button first, so clicks on ✕ will not trigger selection or drag-out; when not hovered,
        // it is transparent and closes hit testing, not affecting the card's click/drag/selection.
        .overlayPreferenceValue(ShelfThumbnailBoundsKey.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let frame = geometry[anchor]
                    let content = item.availability == .available
                        ? thumbnail?.contentBounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                        : CGRect(x: 0, y: 0, width: 1, height: 1)
                    let bounds = CGRect(x: frame.minX + frame.width * content.minX,
                                        y: frame.minY + frame.height * content.minY,
                                        width: frame.width * content.width,
                                        height: frame.height * content.height)
                    removeButton
                        .position(x: bounds.maxX - 4, y: bounds.minY + 4)
                }
            }
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .contextMenu { contextMenu }
        // D9: The card is exposed as a whole to VoiceOver —— name + localized kind (stack with child
        // count) + stale state; selected state uses .isSelected trait; double-click = Quick Look.
        // UX4: The card ignores child elements (✕ is not visible to VoiceOver), and the remove action is
        // exposed via a custom action (can be triggered in rotor 'Actions').
        .accessibilityElement(children: item.availability == .available ? .ignore : .contain)
        .accessibilityIdentifier("shelf.item.\(item.id.uuidString)")
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(Text(cardAccessibilityHint))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activateCard(additive: selectionMode) }
        .accessibilityActions {
            if item.availability == .available,
               quickLookCoordinator != nil,
               ItemActions.canQuickLook(item) {
                Button("Quick Look") { quickLookCoordinator?.toggle(contextItem: item) }
            }
            if item.availability == .available, ItemActions.canOpen(item) {
                Button("Open") {
                    ItemActions.open(item,
                                     bookmarkService: bookmarkService,
                                     tempFileService: tempFileService)
                }
            }
            if item.availability == .available, ItemActions.canRevealInFinder(item) {
                Button("Show in Finder") {
                    ItemActions.revealInFinder(item,
                                               bookmarkService: bookmarkService,
                                               tempFileService: tempFileService)
                }
            }
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
            }
            if let onCopy {
                Button("Copy", action: onCopy)
            }
            if let onRemove {
                Button("Remove from Shelf", action: onRemove)
            }
        }
        .task(id: item) { await loadAssets() }
    }

    private func activateCard(additive: Bool) {
        if item.availability != .available,
           !selectionMode, !additive, !NSEvent.modifierFlags.contains(.shift),
           let onRecover {
            onRecover()
        } else {
            onSelect(selectionMode || additive)
        }
    }

    /// UX4: The remove small circle button appears on hover (SF Symbol xmark, material background ensures
    /// readability on various thumbnails). Click = remove from shelf (`onRemove` is injected by parent
    /// view; if nil, it is not rendered).
    @ViewBuilder
    private var removeButton: some View {
        if !selectionMode, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .frame(width: 18, height: 18)
                    .background { Circle().fill(Color(white: 0.22)) }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isKeyboardFocused ? 1 : 0)
            .allowsHitTesting(isHovering || isKeyboardFocused)
            .help("Remove from Shelf")
            .accessibilityLabel(Text("Remove from Shelf"))
            .accessibilityIdentifier("shelf.item.\(item.id.uuidString).remove")
        }
    }

    /// D9: VoiceOver labels (e.g., 'Report.pdf, File' / 'Screenshots, Stack, 3 Items').
    /// F-05: Cut item appends the semantic of 'the file will be moved when dragged out'.
    private var cardAccessibilityLabel: Text {
        var label = "\(item.displayName), \(Self.localizedKindName(for: item.kind))"
        if item.kind == .stack, let count = item.children?.count {
            label += ", " + String(localized: "\(count) items")
        }
        if item.isCut {
            label += ", " + String(localized: "Managed copy; original file moved to Trash")
        }
        label += isSelected
            ? ", " + String(localized: "Selected")
            : ", " + String(localized: "Not selected")
        if isKeyboardFocused {
            label += ", " + String(localized: "Keyboard focus")
        }
        switch item.availability {
        case .available:
            label += ", " + String(localized: "Available")
        case .externalFileOffline:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Original file unavailable")
        case .managedCopyMissing:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Managed copy missing")
        }
        if let transferStatus {
            label += ", " + transferStatus.localizedDescription
        }
        return Text(label)
    }

    private var cardAccessibilityHint: String {
        if selectionMode {
            return String(localized: "Click to select or deselect.")
        }
        if item.availability != .available {
            return availabilityActionHint
        }
        if item.kind == .stack {
            return String(localized: "Press Return to review the stack.")
        }
        return String(localized: "Press Space for Quick Look or Return to open.")
    }

    /// Localized kind name (for accessibility label).
    static func localizedKindName(for kind: ItemKind) -> String {
        switch kind {
        case .file: String(localized: "File")
        case .folder: String(localized: "Folder")
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        case .url: String(localized: "Link")
        case .stack: String(localized: "Stack")
        }
    }

    // MARK: - Thumbnail area

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack {
            switch item.kind {
            case .text:
                textSnippetPreview
                    .anchorPreference(key: ShelfThumbnailBoundsKey.self, value: .bounds) { $0 }
            case .url:
                urlPlaceholder
            case .file, .folder, .image, .stack:
                if let thumbnail {
                    thumbnail.image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .anchorPreference(key: ShelfThumbnailBoundsKey.self, value: .bounds) { $0 }
                } else {
                    kindPlaceholder
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
    }

    /// A miniature page shares the file thumbnail bounds, rather than filling the tile.
    private var textSnippetPreview: some View {
        let body = ShelfTextDocumentPreview.body(for: item)
        return ZStack(alignment: .topLeading) {
            Color(red: 0.94, green: 0.94, blue: 0.92)
            if body.isEmpty {
                Image(systemName: "doc.text")
                    .font(.system(size: previewHeight * 0.28, weight: .light))
                    .foregroundStyle(Color.black.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(body)
                    .font(.system(size: previewHeight * 0.075, weight: .regular))
                    .fontWeight(.regular)
                    .foregroundStyle(Color.black.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: previewHeight * 0.55, height: previewHeight * 0.83, alignment: .topLeading)
                    .clipped()
                    .padding(previewHeight * 0.085)
            }
        }
        .frame(width: previewHeight * 0.72, height: previewHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "quote.opening")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color(white: 0.20), in: Circle())
                .overlay { Circle().strokeBorder(Color.black.opacity(0.8), lineWidth: 1.5) }
                .offset(x: 4, y: 2)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// url type: SF Symbol link placeholder + domain (S10 can be replaced with real favicon).
    private var urlPlaceholder: some View {
        VStack(spacing: 3) {
            Image(systemName: "link")
                .font(.title3)
            if let host = item.urlString.flatMap({ URL(string: $0)?.host() }) {
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.white.opacity(0.62))
        .anchorPreference(key: ShelfThumbnailBoundsKey.self, value: .bounds) { $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Placeholder before thumbnail loading (symbol taken by kind).
    private var kindPlaceholder: some View {
        Image(systemName: placeholderSymbolName)
            .font(.system(size: 38))
            .foregroundStyle(Color.white.opacity(0.38))
            .anchorPreference(key: ShelfThumbnailBoundsKey.self, value: .bounds) { $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderSymbolName: String {
        switch item.kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .text: "doc.text"
        case .url: "link"
        case .stack: "square.stack.3d.up"
        }
    }

    // MARK: - Availability

    private var availabilityArea: some View {
        Image(systemName: item.kind == .folder ? "folder.fill" : "doc.fill")
            .font(.system(size: 48, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.25))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.65), Color.black)
                    .offset(x: 5, y: 2)
            }
            .anchorPreference(key: ShelfThumbnailBoundsKey.self, value: .bounds) { $0 }
            .frame(maxWidth: .infinity)
            .frame(height: previewHeight)
            .help(availabilityActionHint)
            .accessibilityHidden(true)
    }

    private var availabilityStatusText: String {
        if item.kind == .stack { return String(localized: "Items unavailable") }
        switch item.availability {
        case .available: return String(localized: "Available")
        case .externalFileOffline: return String(localized: "Original missing")
        case .managedCopyMissing: return String(localized: "Managed copy missing")
        }
    }

    private var availabilityActionTitle: String {
        if item.kind == .stack { return String(localized: "Review…") }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline: return String(localized: "Locate Original…")
        case .managedCopyMissing: return String(localized: "Recovery…")
        }
    }

    private var availabilityActionHint: String {
        if item.kind == .stack {
            return String(localized: "Expand the stack to review unavailable items.")
        }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline:
            return String(localized: "Locate the original file to reconnect it.")
        case .managedCopyMissing:
            return String(localized: "Open Storage settings to review recovery data.")
        }
    }

    private var availabilitySymbolName: String {
        switch item.availability {
        case .available: "checkmark.circle"
        case .externalFileOffline: "questionmark.folder"
        case .managedCopyMissing: "externaldrive.badge.exclamationmark"
        }
    }

    // MARK: - Name row

    /// Name line: source app icon + up to two lines of name. Semantic font size changes with system text
    /// size; card expands vertically without shrinking text.
    private var nameRow: some View {
        HStack(alignment: .top, spacing: 3) {
            if let sourceAppIcon {
                Image(nsImage: sourceAppIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            ZStack(alignment: .top) {
                if item.kind == .text {
                    // Reserve the same two-line name height as neighboring file tiles.
                    Text(item.displayName)
                        .lineLimit(2, reservesSpace: true)
                        .hidden()
                    Text(item.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(item.displayName)
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.middle)
                }
            }
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.90))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.displayName)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Surfaces & badges

    /// Card background and selected state (§3: accent border + light fill); non-selected uses semantic
    /// weak background + thin border.
    private var surface: some View {
        RoundedRectangle(cornerRadius: cardCornerRadius)
            .fill(cardFill)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cardCornerRadius)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .strokeBorder(cardBorder, lineWidth: isSelected ? 1 : 0.5)
            }
    }

    private var cardFill: Color {
        Color.white.opacity(isHovering ? 0.06 : 0)
    }

    private var cardBorder: Color {
        isSelected ? Color.accentColor.opacity(0.60) : Color.clear
    }

    @ViewBuilder
    private var keyboardFocusRing: some View {
        if isKeyboardFocused {
            RoundedRectangle(cornerRadius: cardCornerRadius - 2)
                .strokeBorder(selectionMode ? Color.primary.opacity(0.5) : Color(nsColor: .keyboardFocusIndicatorColor),
                              style: StrokeStyle(lineWidth: selectionMode ? 1 : (colorSchemeContrast == .increased ? 4 : 3),
                                                 dash: selectionMode ? [3, 3] : []))
                .padding(2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if selectionMode {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.55), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if isSelected && differentiateWithoutColor {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Context menu

    /// S6 item actions: Quick Look / Open / Show in Finder are disabled based on kind availability; stale
    /// items (bookmark invalid) are meaningless, and display 'File Unavailable' state.
    /// Availability rules and action implementation are in `ItemActions`; Quick Look preview the entire
    /// selected set when multiple selections are hit (rules in `QuickLookPreviewPlanner`).
    @ViewBuilder
    private var contextMenu: some View {
        if item.availability != .available {
            Label(availabilityStatusText, systemImage: availabilitySymbolName)
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
            }
        } else {
            Button("Quick Look") { quickLookCoordinator?.toggle(contextItem: item) }
                .disabled(quickLookCoordinator == nil || !ItemActions.canQuickLook(item))
            Button("Open") {
                ItemActions.open(item, bookmarkService: bookmarkService, tempFileService: tempFileService)
            }
            .disabled(!ItemActions.canOpen(item))
            Button("Show in Finder") {
                ItemActions.revealInFinder(item, bookmarkService: bookmarkService, tempFileService: tempFileService)
            }
            .disabled(!ItemActions.canRevealInFinder(item))
        }
        if let onCopy {
            Button("Copy", action: onCopy)
        }
        if let onRemove {
            Divider()
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
    }

    // MARK: - Asset loading

    /// Load thumbnail and source app icon. QL generation runs in the background, with fallback to
    /// NSWorkspace icon on failure.
    private func loadAssets() async {
        thumbnail = await ThumbnailLoader.thumbnail(
            for: thumbnailItem ?? item,
            pointSize: CGSize(width: previewHeight, height: previewHeight),
            bookmarkService: bookmarkService,
            iconMode: true
        )
        sourceAppIcon = ThumbnailLoader.sourceAppIcon(bundleID: item.sourceApp?.bundleID)
    }
}

/// Visible image bounds exclude the transparent padding in system file icons.
struct ShelfThumbnail {
    let image: Image
    let contentBounds: CGRect

    static func visibleBounds(in image: CGImage) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let scale = min(1, 256 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return unit }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] >= 64 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return unit }
            return CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                          width: CGFloat(maxX - minX + 1) / CGFloat(width),
                          height: CGFloat(maxY - minY + 1) / CGFloat(height))
        }
    }
}

// MARK: - ThumbnailLoader

/// Card thumbnail loading: `QLThumbnailGenerator` real thumbnail + `NSWorkspace` icon fallback.
///
/// Concurrency note (Swift 6 strict concurrency): `QLThumbnailRepresentation`/`NSImage` are not Sendable.
/// QL calls are executed in non-isolated context (results do not cross actor, only return `@unchecked
/// Sendable` `CGImage` to MainActor); NSWorkspace icon is immediately composited into SwiftUI `Image`
/// (Sendable) after synchronous fetching on MainActor, so only `Image`/`CGImage` are exposed externally.
enum ThumbnailLoader {
    /// file/folder/image (kind with disk path): prioritize QL real thumbnail, fallback to NSWorkspace
    /// icon. Return nil if no path (text/url/stack without file children), rendered as placeholder by
    /// card.
    ///
    /// Since S4, unified via bookmark parsing: if `item.bookmark` exists, parse URL and `startAccessing`
    /// (sandboxed restart only allows parsing security-scoped bookmark for file read access), after
    /// loading pair with `stopAccessing`; fallback to original path on parsing failure.
    @MainActor
    static func thumbnail(for item: ShelfItem, pointSize: CGSize, bookmarkService: BookmarkService,
                          iconMode: Bool = false) async -> ShelfThumbnail? {
        guard let baseURL = item.fileURL else { return nil }
        var url = baseURL
        var accessedURL: URL?
        if let bookmark = item.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            url = resolved.url
            if bookmarkService.startAccessing(url) {
                accessedURL = url
            }
        }
        defer {
            if let accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cgImage = await quickLookThumbnail(for: url, pointSize: pointSize, scale: scale, iconMode: iconMode) {
            // S10/C7: register to drag image cache, directly use real thumbnail when dragging out
            // (synchronous path).
            DragImageCache.register(cgImage, for: item.id)
            return ShelfThumbnail(image: Image(decorative: cgImage, scale: scale),
                                  contentBounds: ShelfThumbnail.visibleBounds(in: cgImage))
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var proposedRect = NSRect(origin: .zero, size: icon.size)
        if let cgIcon = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            DragImageCache.register(cgIcon, for: item.id)
            return ShelfThumbnail(image: Image(nsImage: icon), contentBounds: ShelfThumbnail.visibleBounds(in: cgIcon))
        }
        return ShelfThumbnail(image: Image(nsImage: icon), contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Source app small icon; return nil if bundleID is missing or cannot be parsed.
    @MainActor
    static func sourceAppIcon(bundleID: String?) -> NSImage? {
        guard let bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// QL thumbnail generation. Non-isolated: `QLThumbnailRepresentation` is not Sendable, extract CGImage
    /// in-place here to avoid non-Sendable values crossing actor boundaries.
    private nonisolated static func quickLookThumbnail(for url: URL,
                                                       pointSize: CGSize,
                                                       scale: CGFloat,
                                                       iconMode: Bool) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: pointSize, scale: scale, representationTypes: .thumbnail
        )
        // Use the system file-icon decoration instead of styling raw previews ourselves.
        request.iconMode = iconMode
        // Caller (thumbnail(for:pointSize:bookmarkService:)) has already parsed bookmark and started
        // accessing, directly read here. Return nil on generation failure/no thumbnail, fallback to
        // NSWorkspace icon by caller.
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }
}

// MARK: - DragImageCache (S10/C7)

/// Drag image cache: after card thumbnail (QL real thumbnail / NSWorkspace icon fallback) is loaded
/// successfully, register CGImage by item id, available for `DragPayloadBuilder.dragImage` to use on drag
/// initiation synchronous path. CGImage is an immutable value type (Sendable semantic safety), safe to
/// pass across MainActor boundary.
///
/// Capacity cap: clear and rebuild entirely when exceeded — cache miss only fallbacks to system icon, low
/// cost; LRU per item for 64pt small images is not worth it. text/url items have no file thumbnails, not
/// entered into cache (drag image fallback SF Symbol, consistent with card placeholder).
@MainActor
enum DragImageCache {
    private static var images: [UUID: CGImage] = [:]
    private static let capacity = 256

    static func register(_ image: CGImage, for id: UUID) {
        if images.count >= capacity {
            images.removeAll()
        }
        images[id] = image
    }

    static func image(for id: UUID) -> CGImage? {
        images[id]
    }
}

// MARK: - BookmarkService environment

/// Inject BookmarkService into SwiftUI environment (card thumbnail / subsequent open operations via
/// bookmark parsing for file access). Default value for Preview and testing; shared instance injected at
/// App entry.
private struct BookmarkServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue = BookmarkService()
}

extension EnvironmentValues {
    var bookmarkService: BookmarkService {
        get { self[BookmarkServiceEnvironmentKey.self] }
        set { self[BookmarkServiceEnvironmentKey.self] = newValue }
    }
}

// MARK: - Card drag source bridge

/// S5 drag out bridge: each card covers a transparent NSView, as the authoritative mouse event area for
/// the card region.
///
/// Click/drag/double-click arbitration:
/// - `mouseDown` records the press position;
/// - `mouseDragged` displacement exceeds threshold (4pt) → call `onDragBegin` (started by
/// `DragOutController` to launch `beginDraggingSession`; batch/stack expansion on multi-select decided by
/// card's `dragContentsProvider`);
/// - `mouseUp` and no drag → fallback to click: `clickCount >= 2` calls `onDoubleClick` (S6 double-click
/// Quick Look, first click has completed selection, no repeat switch); otherwise single click —
///   first make the window key (nonactivating panel only receives keyboard focus, does not activate app,
/// connects space/Delete/Esc keyboard chain), then call `onClick` (normal click single select / ⌘ click
/// toggle, consistent with S3 semantics).
///
/// Right-click (SwiftUI contextMenu) and scroll pass-through: `hitTest` only takes over during left-click
/// events (ctrl+click is considered a right-click). Once dragging starts, subsequent events are handled by
/// NSDraggingSession.
struct CardDragSourceBridge: NSViewRepresentable {
    /// The item ID corresponding to the anchor (for debugging/logs).
    let itemID: UUID
    /// MouseUp without dragging (click to select). The closure is created in the MainActor lexical context
    /// (View body) and inherits its isolation; explicitly marking @MainActor parameter types will trigger
    /// cross-boundary checks for non-Sendable function values, so keep it as a regular type.
    let onClick: (_ additive: Bool) -> Void
    /// Double-click (S6: Quick Look).
    let onDoubleClick: () -> Void
    /// mouseDragged exceeds threshold; parameters are the anchor view and current event.
    let onDragBegin: (_ sourceView: NSView, _ event: NSEvent) -> Void

    func makeNSView(context: Context) -> CardDragSourceAnchorView {
        let view = CardDragSourceAnchorView()
        view.itemID = itemID
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragBegin = onDragBegin
        return view
    }

    func updateNSView(_ nsView: CardDragSourceAnchorView, context: Context) {
        nsView.itemID = itemID
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragBegin = onDragBegin
    }
}

/// The underlying NSView of `CardDragSourceBridge`.
final class CardDragSourceAnchorView: NSView {
    var itemID: UUID?
    var onClick: ((_ additive: Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegin: ((_ sourceView: NSView, _ event: NSEvent) -> Void)?

    /// Dragging trigger displacement threshold (points).
    static let dragThreshold: CGFloat = 4

    private var mouseDownLocation: NSPoint?
    private var dragStarted = false

    /// Left-click events (excluding ctrl+click, which is equivalent to a right-click) take over this view;
    /// other events are passed through to the underlying SwiftUI content (contextMenu depends on
    /// rightMouseDown, scrolling depends on ScrollView).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return nil
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func takeKeyboardFocus() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        takeKeyboardFocus()
        mouseDownLocation = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let downLocation = mouseDownLocation else { return }
        let location = event.locationInWindow
        let distance = hypot(location.x - downLocation.x, location.y - downLocation.y)
        guard distance >= Self.dragThreshold else { return }
        dragStarted = true
        onDragBegin?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragStarted = false
        }
        // After dragging starts, gestures are taken over by NSDraggingSession, and normal mouseUp events
        // are no longer received; defensive check to avoid misinterpreting the end of dragging as a click.
        guard !dragStarted else { return }
        // A completed click is explicit keyboard intent. Merely becoming key in
        // a nonactivating panel can leave the previous app owning keyboard input.
        NSApp.activate()
        takeKeyboardFocus()
        // S6: Double-click → Quick Look (the first click has already completed the selection, so no switch
        // is made here).
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        // No dragging → click to select. First make the window the key: nonactivating panels only receive
        // keyboard focus and do not activate the app, serving as the entry point for the space/Delete/Esc
        // keyboard chain (ShelfPanel.keyDown).
        onClick?(event.modifierFlags.contains(.command))
    }
}

// MARK: - Previews

#Preview("Item cards") {
    let items = ShelfPreviewFixtures.sampleItems().filter { $0.kind != .stack }
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
        ForEach(items) { item in
            ShelfItemCard(item: item,
                          isSelected: item.kind == .image,
                          onSelect: { _ in },
                          onRemove: {})
        }
    }
    .padding()
    .frame(width: 320)
}
