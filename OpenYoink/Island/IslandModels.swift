import Foundation
import Observation
@_exported import OpenYoinkModuleCore

/// Keep the drag feedback implementation available without displaying it.
enum IslandDragFeedback {
    static let isEnabled = false
}

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
    case compact
    case expanded
    case pinned

    var isExpanded: Bool {
        self == .expanded || self == .pinned
    }
}

/// One source of truth for the two compact wings and their open target.
enum IslandCompactDisplay: Hashable {
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
    enum Event { case entered, left, dwellElapsed, exitElapsed, committed, reset, menuOpened, menuClosed(pointerInside: Bool) }
    enum Action: Equatable {
        case scheduleDwell, cancelDwell, showPreview
        case scheduleExit, cancelExit, dismissPreview, commitPreview
    }

    private(set) var phase: Phase = .idle
    private(set) var isMenuOpen = false

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
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
    /// Exit remains a little quicker, but still visibly morphs back into the
    /// compact surface rather than disappearing before the window shrinks.
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
    private(set) var descriptors: [IslandModuleDescriptor] = [
        .init(id: .shelf, title: String(localized: "Shelf"),
              systemImage: "tray.full", order: 0, isCore: true),
        .init(id: .transfers, title: String(localized: "Transfers"),
              systemImage: "arrow.up.arrow.down", order: 1, isCore: true),
        .init(id: .timer, title: String(localized: "Timer"),
              systemImage: "timer", order: 2, isCore: false),
        .init(id: .battery, title: String(localized: "Battery"),
              systemImage: "battery.75percent", order: 3, isCore: false),
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
        enabledIDs = Set(settings.islandModuleConfiguration.enabledModuleIDs)
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
    private static let extendedModulesKey = "OpenYoink.extendedModuleIDs"

    init(defaults: UserDefaults? = nil) {
        extensionDefaults = defaults
        if let saved = defaults?.stringArray(forKey: Self.extendedModulesKey) {
            extendedModuleIDs = Set(saved.map(IslandModuleID.init(rawValue:)))
        }
    }

    private(set) var surfaceState: IslandSurfaceState = .compact
    /// A completion belongs to one specific transition, even when rapid
    /// close/open/close gestures return to the same surface state.
    private(set) var surfaceTransitionID: UInt64 = 0
    private(set) var isSurfaceTransitionPending = false
    var currentLayout: IslandGeometryResolver.Layout?
    /// Floating (no-notch) Island only: pill, idle dot, or hidden. Visual
    /// state owned by the window controller, which also sizes the panel.
    var floatingPresentation: IslandFloatingPresentation = .capsule
    /// Visual-only hover state. It intentionally does not call
    /// `onStateDidChange`, because pointer movement must never resize the panel.
    var isPointerHovering = false
    /// Visual cue while a file drag is active, before expansion.
    var isFileDragNearby = false
    /// A deliberate collapse must win over hover reveal until the pointer has
    /// actually left the compact surface. Without this latch, the mouse-move
    /// monitor immediately schedules another expansion while the click is
    /// still resting on the notch, which can look like the click selected the
    /// current activity's module instead of collapsing.
    private(set) var isHoverRevealSuppressed = false
    var shortcutSwipeDirection = 1
    var shortcutSwipeOffset: CGFloat = 0
    var shortcutSwipeTarget: IslandModuleID?
    private(set) var shortcutNavigationRevision: UInt64 = 0
    static let reentryGraceSeconds: TimeInterval = 3
    private var lastDepartedModule: IslandModuleID?
    private var reentryDeadline: TimeInterval = 0
    var quickSettingsShowsCompact = false

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
    private(set) var activities: [String: IslandActivity] = [:]
    private var stateBeforeDrag: IslandSurfaceState?
    private var moduleBeforeDrag: IslandModuleID?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?
    @ObservationIgnored private var firstPublishedAt: [String: Date] = [:]
    private var spotlightRevision: UInt64 = 0

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
        if previousState.isExpanded, state == .compact { rememberDeparture() }
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

    func toggle() {
        if surfaceState.isExpanded {
            collapse()
        } else {
            show(module: selectedModule)
        }
    }

    func collapse(suppressHoverUntilPointerExit: Bool = true) {
        isHoverRevealSuppressed = suppressHoverUntilPointerExit
        setSurfaceState(.compact)
    }

    func setPinned(_ pinned: Bool) {
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func hide() {
        setSurfaceState(.hidden)
    }

    func publish(_ activity: IslandActivity?, at date: Date = Date()) {
        guard let activity else { return }
        if activities[activity.id] == nil {
            // Republishing an alert with fresh numbers must not restart its
            // spotlight, or a recurring warning could hold the notch forever.
            firstPublishedAt[activity.id] = date
        }
        activities[activity.id] = activity
        scheduleExpiry()
        scheduleSpotlightEnd(at: date)
        onStateDidChange?()
    }

    func removeActivity(id: String) {
        guard activities.removeValue(forKey: id) != nil else { return }
        firstPublishedAt[id] = nil
        scheduleExpiry()
        onStateDidChange?()
    }

    func removeActivities(for moduleID: IslandModuleID) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.moduleID != moduleID }
        if activities.count != previousCount {
            forgetRemovedActivities()
            scheduleExpiry()
            onStateDidChange?()
        }
    }

    /// Advisory alerts (AI limits, system load, power changes) announce
    /// themselves in the compact Island for this long, then hand it back to
    /// Now Playing. They stay published, so the module still shows them and
    /// they return to the notch once media goes away. Critical battery,
    /// finished timers, transfers and drags keep outranking media.
    static let advisorySpotlightDuration: TimeInterval = 8

    func primaryActivity(at date: Date = Date()) -> IslandActivity? {
        rankedActivity(at: date, filterSelectedModule: true)
    }

    func compactPrimaryActivity(at date: Date = Date()) -> IslandActivity? {
        rankedActivity(at: date, filterSelectedModule: false)
    }

    private func rankedActivity(at date: Date, filterSelectedModule: Bool) -> IslandActivity? {
        // Read so SwiftUI re-evaluates when a spotlight ends, which changes the
        // answer without any activity changing.
        _ = spotlightRevision
        let candidates = activities.values
            .filter { $0.isActive(at: date) }
            .filter { activity in
                !filterSelectedModule || activity.priority != .selectedModule
                    || activity.moduleID == selectedModule
            }
        let hasMedia = candidates.contains { $0.priority == .nowPlaying }
        func rank(_ activity: IslandActivity) -> Int {
            guard hasMedia, isAdvisory(activity), !isInSpotlight(activity, at: date) else {
                return activity.priority.rawValue
            }
            return IslandActivityPriority.nowPlaying.rawValue - 1
        }
        return candidates.max { lhs, rhs in
            let lhsRank = rank(lhs), rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    func pruneExpired(at date: Date = Date()) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.isActive(at: date) }
        forgetRemovedActivities()
        scheduleExpiry()
        if activities.count != previousCount { onStateDidChange?() }
    }

    private func isAdvisory(_ activity: IslandActivity) -> Bool {
        activity.priority == .powerChange || activity.priority == .systemWarning
    }

    private func isInSpotlight(_ activity: IslandActivity, at date: Date) -> Bool {
        guard let start = firstPublishedAt[activity.id] else { return false }
        return date.timeIntervalSince(start) < Self.advisorySpotlightDuration
    }

    private func forgetRemovedActivities() {
        firstPublishedAt = firstPublishedAt.filter { activities[$0.key] != nil }
    }

    private func scheduleSpotlightEnd(at date: Date) {
        spotlightTask?.cancel()
        let pendingEnds = activities.values
            .filter(isAdvisory)
            .compactMap { firstPublishedAt[$0.id] }
            .map { $0.addingTimeInterval(Self.advisorySpotlightDuration) }
            .filter { $0 > date }
        guard let nextEnd = pendingEnds.min() else {
            spotlightTask = nil
            return
        }
        let delay = nextEnd.timeIntervalSince(date)
        spotlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.spotlightRevision &+= 1
            self.scheduleSpotlightEnd(at: Date())
            self.onStateDidChange?()
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let nextExpiry = activities.values.compactMap(\.expiresAt).min() else {
            expiryTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
        }
    }

    func beginDrag() {
        isFileDragNearby = false
        if stateBeforeDrag == nil {
            stateBeforeDrag = surfaceState
            moduleBeforeDrag = selectedModule
        }
        selectedModule = .shelf
        publish(.init(id: "drag", moduleID: .shelf, priority: .userDrag,
                      title: String(localized: "Drop into OpenYoink"), detail: nil,
                      systemImage: "arrow.down.to.line", expiresAt: nil))
        setSurfaceState(.expanded)
    }

    func endDrag(imported: Bool) {
        removeActivity(id: "drag")
        defer {
            stateBeforeDrag = nil
            moduleBeforeDrag = nil
        }
        guard !imported else {
            setSurfaceState(.expanded)
            return
        }
        if let moduleBeforeDrag { selectedModule = moduleBeforeDrag }
        setSurfaceState(stateBeforeDrag ?? .compact)
    }
}
