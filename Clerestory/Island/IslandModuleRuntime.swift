import SwiftUI

/// Runtime boundary shared by every first-party Island module. The event
/// stream is deliberately independent from SwiftUI so lifecycle and event
/// routing stay testable and cancellable. Modules that have a `ModuleMessenger`
/// set statuses directly instead of sending activity events.
@MainActor
protocol IslandModuleRuntime: AnyObject {
    var descriptor: IslandModuleDescriptor { get }
    var events: AsyncStream<IslandModuleEvent> { get }
    func start()
    func stop()
}

/// A registration owns all factories associated with one module. The root
/// Island view only asks the container for content and never switches on IDs.
struct IslandModuleViewContext {
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenModule: (IslandModuleID) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
}

struct IslandModuleRegistration: Identifiable {
    let descriptor: IslandModuleDescriptor
    let runtime: any IslandModuleRuntime
    let makeContentView: @MainActor (IslandModuleViewContext) -> AnyView
    let makeSettingsView: @MainActor () -> AnyView

    var id: IslandModuleID { descriptor.id }

    init(
        descriptor: IslandModuleDescriptor,
        runtime: any IslandModuleRuntime,
        makeContentView: @escaping @MainActor (IslandModuleViewContext) -> AnyView,
        makeSettingsView: @escaping @MainActor () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.descriptor = descriptor
        self.runtime = runtime
        self.makeContentView = makeContentView
        self.makeSettingsView = makeSettingsView
    }
}

/// Adapts the existing first-party stores to the stream-based module boundary.
/// Stores retain their focused responsibilities while the container becomes
/// the only consumer of activity callbacks and lifecycle methods.
@MainActor
final class CallbackIslandModuleRuntime: IslandModuleRuntime {
    let descriptor: IslandModuleDescriptor
    let events: AsyncStream<IslandModuleEvent>

    private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    private let startAction: @MainActor () -> Void
    private let stopAction: @MainActor () -> Void
    private(set) var isRunning = false
    private var publishedActivityID: String?

    init(
        descriptor: IslandModuleDescriptor,
        start: @escaping @MainActor () -> Void = {},
        stop: @escaping @MainActor () -> Void = {}
    ) {
        self.descriptor = descriptor
        self.startAction = start
        self.stopAction = stop
        var capturedContinuation: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startAction()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopAction()
    }

    /// Replaces the module's one activity. Only an activity with another id is removed first,
    /// so an update does not clear and re-add its status.
    func replaceActivity(_ activity: IslandActivity?) {
        if let publishedActivityID, publishedActivityID != activity?.id {
            continuation.yield(.removeActivity(id: publishedActivityID))
        }
        if let activity { continuation.yield(.publishActivity(activity)) }
        publishedActivityID = activity?.id
    }

    func publish(_ event: IslandModuleEvent) {
        continuation.yield(event)
    }
}

/// Transfers owns the single mapping from transfer state to Island activity.
/// Both classic-shelf layout changes and Island activity refreshes may call
/// `refresh`, but only this runtime publishes the resulting module event.
@MainActor
final class TransfersModuleRuntime: IslandModuleRuntime {
    let descriptor = IslandModuleDescriptor(
        id: .transfers,
        title: String(localized: "Transfers"),
        systemImage: "arrow.up.arrow.down",
        order: 1,
        isCore: false
    )
    let events: AsyncStream<IslandModuleEvent>

    private let transferStore: TransferStore
    private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    private(set) var isRunning = false

    init(transferStore: TransferStore) {
        self.transferStore = transferStore
        var capturedContinuation: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        continuation.yield(.removeAllActivities)
    }

    /// Its one activity id is "transfer", so a new task updates it in place.
    func refresh() {
        guard isRunning else { return }
        if let task = transferStore.currentTask {
            continuation.yield(.publishActivity(Self.activity(for: task)))
        } else {
            continuation.yield(.removeAllActivities)
        }
    }

    private static func activity(for task: TransferTask) -> IslandActivity {
        let title: String
        let symbol: String
        switch task.phase {
        case .failed:
            title = String(localized: "Transfer failed")
            symbol = "exclamationmark.octagon.fill"
        case .partiallySucceeded:
            title = String(localized: "Transfer completed with warnings")
            symbol = "exclamationmark.triangle.fill"
        case .targetAccepted, .delivered:
            title = String(localized: "Transfer complete")
            symbol = "checkmark.circle.fill"
        case .cancelled:
            title = String(localized: "Transfer cancelled")
            symbol = "xmark.circle"
        default:
            title = String(localized: "Transferring content…")
            symbol = "arrow.up.arrow.down"
        }
        return IslandActivity(
            id: "transfer",
            moduleID: .transfers,
            priority: .transfer,
            title: title,
            detail: nil,
            systemImage: symbol,
            expiresAt: nil
        )
    }
}

@MainActor
@Observable
final class IslandModuleContainer {
    private(set) var registrations: [IslandModuleRegistration]
    private(set) var availability: [IslandModuleID: IslandModuleAvailability] = [:]
    private(set) var runningModuleIDs: Set<IslandModuleID> = []

    @ObservationIgnored private let messages: IslandMessageCenter
    @ObservationIgnored private var eventTasks: [IslandModuleID: Task<Void, Never>] = [:]

    init(
        registrations: [IslandModuleRegistration],
        messages: IslandMessageCenter
    ) {
        var seen = Set<IslandModuleID>()
        self.registrations = registrations
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.descriptor.order < $1.descriptor.order }
        self.messages = messages
    }

    deinit {
        for task in eventTasks.values { task.cancel() }
    }

    var registeredModuleIDs: Set<IslandModuleID> {
        Set(registrations.map(\.id))
    }

    func registration(for id: IslandModuleID) -> IslandModuleRegistration? {
        registrations.first { $0.id == id }
    }

    func contentView(
        for id: IslandModuleID,
        context: IslandModuleViewContext
    ) -> AnyView {
        registration(for: id)?.makeContentView(context) ?? AnyView(
            ContentUnavailableView(
                String(localized: "Module unavailable"),
                systemImage: "puzzlepiece.extension",
                description: Text("This module is not available in this version of Clerestory.")
            )
        )
    }

    func apply(configuration: IslandModuleConfiguration, isActive: Bool) {
        let desired = isActive
            ? Set(configuration.enabledModuleIDs).union([.quickSettings]).intersection(registeredModuleIDs)
            : []
        for registration in registrations {
            if desired.contains(registration.id) {
                start(registration)
            } else {
                stop(registration)
            }
        }
    }

    func stopAll() {
        for registration in registrations { stop(registration) }
    }

    private func start(_ registration: IslandModuleRegistration) {
        guard runningModuleIDs.insert(registration.id).inserted else { return }
        let moduleID = registration.id
        let stream = registration.runtime.events
        eventTasks[moduleID] = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.consume(event, from: moduleID)
            }
        }
        // Before start(), so a status the module sets while starting is accepted.
        messages.moduleDidStart(moduleID)
        registration.runtime.start()
        availability[moduleID] = .available
    }

    private func stop(_ registration: IslandModuleRegistration) {
        guard runningModuleIDs.remove(registration.id) != nil else { return }
        registration.runtime.stop()
        eventTasks.removeValue(forKey: registration.id)?.cancel()
        // After stop(), so nothing the module sets while stopping outlives it.
        messages.moduleDidStop(registration.id)
        availability.removeValue(forKey: registration.id)
    }

    private func consume(_ event: IslandModuleEvent, from moduleID: IslandModuleID) {
        guard runningModuleIDs.contains(moduleID) else { return }
        if case let .availabilityChanged(next) = event {
            availability[moduleID] = next
            return
        }
        IslandActivityStatusAdapter.apply(event, to: messages.messenger(for: moduleID))
    }
}

/// TEMPORARY (issue #80, PR 3): turns the old activity events of modules that do not have a
/// `ModuleMessenger` yet into statuses. Delete it in PR 4, together with IslandActivity,
/// IslandActivityPriority and IslandModuleEvent, once every module sets statuses itself.
///
/// The messenger is the one for the module whose stream sent the event, so a module can only
/// change its own statuses. Adapted statuses never announce: whether a module's raised
/// statuses show a pill and speak is decided per module when it migrates.
@MainActor
enum IslandActivityStatusAdapter {
    static func apply(_ event: IslandModuleEvent, to messenger: ModuleMessenger) {
        switch event {
        case let .publishActivity(activity):
            // An activity for another module is ignored rather than moved.
            guard activity.moduleID == messenger.moduleID else { return }
            messenger.setStatus(status(for: activity, expiresAt: activity.expiresAt.map {
                messenger.expiry(after: .seconds($0.timeIntervalSinceNow))
            }))
        case let .removeActivity(id):
            messenger.clearStatus(id)
        case .removeAllActivities:
            messenger.setStatuses([])
        case .availabilityChanged:
            break
        }
    }

    /// Keeps each priority's notch tint: critical battery red; system warnings and finished
    /// timers orange; transfers and drags accent; everything else white.
    static func tone(for priority: IslandActivityPriority) -> IslandStatus.Tone {
        switch priority {
        case .criticalBattery: .critical
        case .systemWarning, .timerFinished: .warning
        case .transfer, .userDrag: .progress
        case .shelfSummary, .selectedModule, .nowPlaying, .powerChange: .neutral
        }
    }

    static func status(for activity: IslandActivity, expiresAt: Duration?) -> IslandStatus {
        IslandStatus(key: activity.id, title: activity.title, detail: activity.detail,
                     systemImage: activity.systemImage, tone: tone(for: activity.priority),
                     announcesWhenRaised: false, expiresAt: expiresAt)
    }
}
