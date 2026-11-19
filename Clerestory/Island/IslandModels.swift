import Foundation
import Observation
@_exported import ClerestoryModuleCore

/// One page per horizontal trackpad gesture; vertical gestures stay with content.
struct IslandShortcutSwipe {
    static func target(current: IslandModuleID, step: Int, pinned: [IslandModuleID],
                       enabled: (IslandModuleID) -> Bool) -> IslandModuleID? {
        var pages = pinned.filter { $0 == .quickSettings || enabled($0) }
        if !pages.contains(.quickSettings) { pages.append(.quickSettings) }
        let next = pages.firstIndex(of: current).map { $0 + step } ?? (step > 0 ? 0 : pages.count - 1)
        return pages.indices.contains(next) ? pages[next] : nil
    }

    static func shouldCommit(projected: CGFloat, direction: Int, width: CGFloat,
                             hasTarget: Bool, cancelled: Bool) -> Bool {
        !cancelled && hasTarget && -CGFloat(direction) * projected >= width * 0.18
    }
    enum Result: Equatable { case ignored, consumed, drag(CGFloat) }
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var horizontal = false
    private var vertical = false
    private var velocity: CGFloat = 0
    private var lastSampleTime: TimeInterval?

    mutating func sample(dx: CGFloat, dy: CGFloat, began: Bool,
                         momentum: Bool, timestamp: TimeInterval = 0) -> Result {
        if began { self = Self() }
        if momentum { return horizontal ? .consumed : .ignored }
        if vertical { return .ignored }
        let interval = lastSampleTime.map { timestamp - $0 } ?? (1.0 / 60.0)
        if interval > 0 {
            let instantaneous = dx / max(1.0 / 120.0, interval)
            velocity = interval > 0.12 ? instantaneous : velocity * 0.35 + instantaneous * 0.65
        }
        lastSampleTime = timestamp
        x += dx
        y += dy
        if !horizontal {
            if abs(y) >= 8 && abs(y) > abs(x) * 1.2 {
                vertical = true
                return .ignored
            }
            guard abs(x) >= 8 && abs(x) > abs(y) * 1.3 else { return .ignored }
            horizontal = true
        }
        return .drag(x)
    }

    func projectedTranslation(at timestamp: TimeInterval) -> CGFloat {
        guard horizontal, abs(x) >= 12, let lastSampleTime,
              timestamp - lastSampleTime < 0.12 else { return x }
        return x + velocity * 0.20
    }
}

extension IslandModuleID {
    static let quickSettings = Self(rawValue: "quickSettings")
    static let shelf = Self(rawValue: "shelf")
    static let transfers = Self(rawValue: "transfers")
    static let timer = Self(rawValue: "timer")
    static let battery = Self(rawValue: "battery")
    static let media = Self(rawValue: "media")
    static let system = Self(rawValue: "system")
    static let folders = Self(rawValue: "folders")
    static let clipboard = Self(rawValue: "clipboard")
    static let aiUsage = Self(rawValue: "aiUsage")
}

enum IslandSurfaceState: Equatable, Sendable {
    case hidden
    case collapsed
    case expanded
    case pinned

    var isExpanded: Bool {
        self == .expanded || self == .pinned
    }
}

/// One source of truth for the two notch wings and their open target.
enum IslandNotchDisplay: Hashable {
    case media, transfers, timer, aiUsage, shelf, battery, fallback

    var moduleID: IslandModuleID? {
        switch self {
        case .media: .media
        case .transfers: .transfers
        case .timer: .timer
        case .aiUsage: .aiUsage
        case .shelf: .shelf
        case .battery: .battery
        case .fallback: nil
        }
    }

    var systemImage: String {
        switch self {
        case .media: "music.note"
        case .transfers: "arrow.up.arrow.down"
        case .timer: "timer"
        case .aiUsage: "chart.line.uptrend.xyaxis"
        case .shelf: "tray.full"
        case .battery: "battery.75percent"
        case .fallback: "sparkles"
        }
    }

    static let cycleOrder: [IslandModuleID] = [.shelf, .transfers, .timer, .battery, .media, .aiUsage]

    static func selected(_ module: IslandModuleID, enabled: [IslandModuleID], order: [IslandModuleID] = cycleOrder) -> Self {
        let available = order.filter { cycleOrder.contains($0) && enabled.contains($0) }
        guard let resolved = available.contains(module) ? module : available.first else { return .fallback }
        switch resolved {
        case .shelf: return .shelf
        case .transfers: return .transfers
        case .timer: return .timer
        case .battery: return .battery
        case .media: return .media
        case .aiUsage: return .aiUsage
        default: return .fallback
        }
    }

    static func next(after module: IslandModuleID, enabled: [IslandModuleID], backwards: Bool = false, order: [IslandModuleID] = cycleOrder) -> IslandModuleID? {
        let available = order.filter { cycleOrder.contains($0) && enabled.contains($0) }
        guard !available.isEmpty else { return nil }
        let index = available.firstIndex(of: module) ?? 0
        return available[(index + (backwards ? -1 : 1) + available.count) % available.count]
    }

}

/// Hover expansion is temporary until the user clicks or pins the Island.
struct IslandHoverPreviewStateMachine {
    enum Phase: Equatable { case idle, dwelling, preview, leaving }
    enum Event { case entered, left, dwellElapsed, exitElapsed, committed, unpinned(pointerInside: Bool), reset, menuOpened, menuClosed(pointerInside: Bool) }
    enum Action: Equatable {
        case scheduleDwell, cancelDwell, showPreview
        case scheduleExit, cancelExit, dismissPreview, commitPreview
    }

    private(set) var phase: Phase = .idle
    private(set) var isMenuOpen = false

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .unpinned(let pointerInside):
            // The panel is already open; resume dismissal without revealing it
            // again or changing the module the user was working in.
            phase = .preview
            return [.cancelDwell, .cancelExit] + (pointerInside ? [] : handle(.left))
        case .menuOpened:
            isMenuOpen = true
            if phase == .leaving { phase = .preview; return [.cancelExit] }
            return []
        case .menuClosed(let pointerInside):
            isMenuOpen = false
            return handle(pointerInside ? .entered : .left)
        case .reset:
            isMenuOpen = false
        case .left, .exitElapsed:
            if isMenuOpen { return [] }
        default: break
        }
        switch (phase, event) {
        case (.idle, .entered):
            phase = .dwelling
            return [.scheduleDwell]
        case (.dwelling, .left), (.dwelling, .reset):
            phase = .idle
            return [.cancelDwell]
        case (.dwelling, .dwellElapsed):
            phase = .preview
            return [.showPreview]
        case (.preview, .left):
            phase = .leaving
            return [.scheduleExit]
        case (.leaving, .entered):
            phase = .preview
            return [.cancelExit]
        case (.leaving, .exitElapsed):
            phase = .idle
            return [.dismissPreview]
        case (.preview, .committed):
            phase = .idle
            return [.commitPreview]
        case (.leaving, .committed):
            phase = .idle
            return [.cancelExit, .commitPreview]
        case (.preview, .reset):
            phase = .idle
            return [.dismissPreview]
        case (.leaving, .reset):
            phase = .idle
            return [.cancelExit, .dismissPreview]
        case (.dwelling, .committed):
            phase = .idle
            return [.cancelDwell]
        default:
            return []
        }
    }
}

/// Shared timing keeps the SwiftUI silhouette transition and the AppKit panel
/// resize in one rhythm. On collapse the visible surface finishes tucking into
/// the notch before the now-transparent window footprint is reduced.
enum IslandMotion {
    /// Match the Web demo's continuous notch morph: the AppKit canvas and the
    /// SwiftUI reveal share a single, velocity-preserving visual rhythm.
    static let expandContentDuration: TimeInterval = 0.38
    static let expandWindowDuration: TimeInterval = 0.38
    /// Keep the panel exit slightly quicker than entry while allowing its
    /// content, background, and shadow to finish together.
    static let collapseContentDuration: TimeInterval = 0.28
    static let collapseWindowDuration: TimeInterval = 0.30
}

/// Internal-only module contract. v1.4.x deliberately does not load external
/// bundles; the protocol keeps first-party lifecycles consistent and gives a
/// future SDK a stable conceptual boundary.
@MainActor
protocol IslandModule: AnyObject {
    var descriptor: IslandModuleDescriptor { get }
    func start()
    func stop()
}

@MainActor
@Observable
final class IslandModuleRegistry {
    /// Required navigation module; its shortcut may occupy any position.
    static let quickSettingsDescriptor = IslandModuleDescriptor(
        id: .quickSettings, title: String(localized: "Quick Settings"),
        systemImage: "square.grid.2x2", order: -1, isCore: true, supportsExtendedHeight: true)
    static let batteryDescriptor = IslandModuleDescriptor(
        id: .battery, title: String(localized: "Battery"),
        systemImage: "battery.75percent", order: 3, isCore: false, supportsExtendedHeight: true)
    private(set) var descriptors: [IslandModuleDescriptor] = [
        .init(id: .shelf, title: String(localized: "Shelf"),
              systemImage: "tray.full", order: 0, isCore: true, supportsExtendedHeight: true),
        .init(id: .transfers, title: String(localized: "Transfers"),
              systemImage: "arrow.up.arrow.down", order: 1, isCore: false),
        .init(id: .timer, title: String(localized: "Timer"),
              systemImage: "timer", order: 2, isCore: false),
        IslandModuleRegistry.batteryDescriptor,
        .init(id: .system, title: String(localized: "System Status"),
              systemImage: "gauge.with.dots.needle.67percent", order: 4, isCore: false),
        .init(id: .media, title: String(localized: "Now Playing"),
              systemImage: "music.note", order: 5, isCore: false),
        .init(id: .folders, title: String(localized: "Quick Access"),
              systemImage: "folder", order: 6, isCore: false),
        .init(id: .clipboard, title: String(localized: "Clipboard History"),
              systemImage: "doc.on.clipboard", order: 7, isCore: false),
        AIUsageModuleStore.moduleDescriptor,
    ]

    private(set) var enabledIDs: Set<IslandModuleID> = [.shelf, .transfers]

    func apply(settings: SettingsStore) {
        enabledIDs = Set(settings.effectiveIslandModuleConfiguration.enabledModuleIDs)
    }

    var enabledDescriptors: [IslandModuleDescriptor] {
        descriptors
            .filter { enabledIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    func isEnabled(_ id: IslandModuleID) -> Bool {
        id == .quickSettings || enabledIDs.contains(id)
    }

    func descriptor(for id: IslandModuleID) -> IslandModuleDescriptor? {
        id == .quickSettings ? Self.quickSettingsDescriptor : descriptors.first { $0.id == id }
    }
}

@MainActor
@Observable
final class IslandActivityCoordinator {
    @ObservationIgnored private let extensionDefaults: UserDefaults?
    private static let extendedModulesKey = "Clerestory.extendedModuleIDs"

    init(defaults: UserDefaults? = nil) {
        extensionDefaults = defaults
        if let saved = defaults?.stringArray(forKey: Self.extendedModulesKey) {
            extendedModuleIDs = Set(saved.map(IslandModuleID.init(rawValue:)))
        }
    }

    private(set) var surfaceState: IslandSurfaceState = .collapsed
    /// A completion belongs to one specific transition, even when rapid
    /// close/open/close gestures return to the same surface state.
    private(set) var surfaceTransitionID: UInt64 = 0
    private(set) var isSurfaceTransitionPending = false
    var notchLayout: IslandGeometryResolver.Layout?
    var currentLayout: IslandGeometryResolver.Layout?
    /// Floating (no-notch) Island only: pill, idle dot, or hidden. Visual
    /// state owned by the window controller, which also sizes the panel.
    var floatingPresentation: IslandFloatingPresentation = .capsule
    /// Visual-only hover state. It intentionally does not call
    /// `onStateDidChange`, because pointer movement must never resize the panel.
    var isPointerHovering = false
    /// A deliberate collapse must win over hover reveal until the pointer has
    /// actually left the notch surface. Without this latch, the mouse-move
    /// monitor immediately schedules another expansion while the click is
    /// still resting on the notch, which can look like the click selected the
    /// notch's module instead of collapsing.
    private(set) var isHoverRevealSuppressed = false
    var shortcutSwipeDirection = 1
    var shortcutSwipeOffset: CGFloat = 0
    var shortcutSwipeTarget: IslandModuleID?
    private(set) var shortcutNavigationRevision: UInt64 = 0
    static let reentryGraceSeconds: TimeInterval = 3
    private var lastDepartedModule: IslandModuleID?
    private var reentryDeadline: TimeInterval = 0
    var quickSettingsShowsNotch = false

    func rememberDeparture(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastDepartedModule = selectedModule
        reentryDeadline = uptime + Self.reentryGraceSeconds
    }

    func reentryModule(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       isEnabled: (IslandModuleID) -> Bool) -> IslandModuleID? {
        guard uptime < reentryDeadline, let module = lastDepartedModule,
              isEnabled(module) else { return nil }
        return module
    }

    private(set) var extendedModuleIDs = Set<IslandModuleID>()
    private(set) var moduleContentHeights: [IslandModuleID: CGFloat] = [:]

    func isModuleExtended(_ descriptor: IslandModuleDescriptor) -> Bool {
        descriptor.supportsExtendedHeight && extendedModuleIDs.contains(descriptor.id)
    }

    func setModuleExtended(_ extended: Bool, descriptor: IslandModuleDescriptor) {
        guard descriptor.supportsExtendedHeight else { return }
        let wasExtended = extendedModuleIDs.contains(descriptor.id)
        if extended { extendedModuleIDs.insert(descriptor.id) }
        else { extendedModuleIDs.remove(descriptor.id) }
        if wasExtended != extended {
            extensionDefaults?.set(extendedModuleIDs.map(\.rawValue).sorted(), forKey: Self.extendedModulesKey)
            if selectedModule == descriptor.id { onStateDidChange?() }
        }
    }

    func recordModuleContentHeight(_ height: CGFloat, descriptor: IslandModuleDescriptor) {
        guard descriptor.supportsExtendedHeight, height.isFinite else { return }
        let target = max(IslandGeometryResolver.expandedPreferredHeight, ceil(height))
        guard abs((moduleContentHeights[descriptor.id] ?? 0) - target) >= 1 else { return }
        moduleContentHeights[descriptor.id] = target
        if isModuleExtended(descriptor), selectedModule == descriptor.id { onStateDidChange?() }
    }

    func preferredExpandedHeight(for descriptor: IslandModuleDescriptor?) -> CGFloat {
        guard let descriptor, isModuleExtended(descriptor) else {
            return IslandGeometryResolver.expandedPreferredHeight
        }
        return moduleContentHeights[descriptor.id] ?? IslandGeometryResolver.expandedPreferredHeight
    }
    var selectedModule: IslandModuleID = .shelf {
        didSet {
            shortcutNavigationRevision &+= 1
            shortcutSwipeOffset = 0
            shortcutSwipeTarget = nil
            guard oldValue != selectedModule else { return }
            onStateDidChange?()
        }
    }
    /// A file or text drag toward Shelf is in progress. The notch shows the drop arrow.
    private(set) var isDragInProgress = false
    private var stateBeforeDrag: IslandSurfaceState?
    private var moduleBeforeDrag: IslandModuleID?

    var onSurfaceStateWillChange: (@MainActor (
        IslandSurfaceState,
        IslandSurfaceState
    ) -> Void)?
    var onStateDidChange: (@MainActor () -> Void)?
    @ObservationIgnored var onSurfaceAnimationCompleted: (@MainActor () -> Void)?

    func setSurfaceState(_ state: IslandSurfaceState) {
        guard surfaceState != state else { return }
        shortcutNavigationRevision &+= 1
        if !state.isExpanded {
            shortcutSwipeOffset = 0
            shortcutSwipeTarget = nil
        }
        let previousState = surfaceState
        if previousState.isExpanded, state == .collapsed { rememberDeparture() }
        onSurfaceStateWillChange?(previousState, state)
        surfaceState = state
        surfaceTransitionID &+= 1
        isSurfaceTransitionPending = true
        if state.isExpanded {
            isPointerHovering = false
            isHoverRevealSuppressed = false
        }
        onStateDidChange?()
    }

    func completeSurfaceTransition(_ transitionID: UInt64) {
        guard transitionID == surfaceTransitionID, isSurfaceTransitionPending else { return }
        isSurfaceTransitionPending = false
        onSurfaceAnimationCompleted?()
    }

    /// A delayed settle cannot override a later click, collapse, or reopened page.
    func completeShortcutSwipe(target: IslandModuleID?, revision: UInt64) {
        guard shortcutNavigationRevision == revision, surfaceState.isExpanded else { return }
        if let target { selectedModule = target }
        shortcutSwipeOffset = 0
        shortcutSwipeTarget = nil
    }

    func setPointerHovering(_ hovering: Bool) {
        // Clear the deliberate-collapse latch on exit even if the visual
        // hover value was already false. The next genuine pointer entry may
        // then reveal the Island normally.
        if !hovering { isHoverRevealSuppressed = false }
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
    }

    var canRevealOnHover: Bool {
        !isHoverRevealSuppressed
    }

    func show(module: IslandModuleID = .shelf, pinned: Bool = false) {
        selectedModule = module
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    /// The companion can change the displayed module without releasing a pin.
    func showFromNotch(module: IslandModuleID) {
        show(module: module, pinned: surfaceState == .pinned)
    }

    func toggle() {
        if surfaceState.isExpanded {
            collapse()
        } else {
            show(module: selectedModule)
        }
    }

    func collapse(suppressHoverUntilPointerExit: Bool = true) {
        isHoverRevealSuppressed = suppressHoverUntilPointerExit
        setSurfaceState(.collapsed)
    }

    func setPinned(_ pinned: Bool) {
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func hide() {
        setSurfaceState(.hidden)
    }

    func beginDrag() {
        if stateBeforeDrag == nil {
            stateBeforeDrag = surfaceState
            moduleBeforeDrag = selectedModule
        }
        selectedModule = .shelf
        if !isDragInProgress {
            isDragInProgress = true
            onStateDidChange?()
        }
        setSurfaceState(.expanded)
    }

    func endDrag(imported: Bool, hasPendingNotice: Bool = false) {
        if isDragInProgress {
            isDragInProgress = false
            onStateDidChange?()
        }
        defer {
            stateBeforeDrag = nil
            moduleBeforeDrag = nil
        }
        // New drop feedback waits for the transient drag-opened panel to close.
        guard !imported || hasPendingNotice else {
            setSurfaceState(.expanded)
            return
        }
        if let moduleBeforeDrag { selectedModule = moduleBeforeDrag }
        setSurfaceState(stateBeforeDrag ?? .collapsed)
    }
}
