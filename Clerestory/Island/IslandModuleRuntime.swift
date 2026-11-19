import SwiftUI

/// Runtime boundary shared by every first-party Island module. The container only drives its
/// lifecycle; a module writes its statuses and notices through its own `ModuleMessenger`, so a
/// module that stops and starts again keeps reaching the message center.
@MainActor
protocol IslandModuleRuntime: AnyObject {
    var descriptor: IslandModuleDescriptor { get }
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

/// Runs a first-party store's lifecycle for the container. Stores set their statuses through
/// their own `ModuleMessenger`, so this only forwards `start` and `stop`.
@MainActor
final class CallbackIslandModuleRuntime: IslandModuleRuntime {
    let descriptor: IslandModuleDescriptor

    private let startAction: @MainActor () -> Void
    private let stopAction: @MainActor () -> Void
    private(set) var isRunning = false

    init(
        descriptor: IslandModuleDescriptor,
        start: @escaping @MainActor () -> Void = {},
        stop: @escaping @MainActor () -> Void = {}
    ) {
        self.descriptor = descriptor
        self.startAction = start
        self.stopAction = stop
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
}

/// Transfers owns the single mapping from transfer state to its one Notch status. TransferStore
/// and its strip present the transfer itself; the status only gives the Notch its icon and tint.
/// It never announces: the transfer planner already speaks and the strip shows failures.
@MainActor
final class TransfersModuleRuntime: IslandModuleRuntime {
    let descriptor = IslandModuleDescriptor(
        id: .transfers,
        title: String(localized: "Transfers"),
        systemImage: "arrow.up.arrow.down",
        order: 1,
        isCore: false
    )

    private let transferStore: TransferStore
    private let messenger: ModuleMessenger
    private(set) var isRunning = false
    /// Bumped by every start and stop, so an observation from an earlier run stops re-arming.
    private var run: UInt64 = 0

    init(transferStore: TransferStore, messenger: ModuleMessenger = .inert) {
        self.transferStore = transferStore
        self.messenger = messenger
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        run &+= 1
        observe(run: run)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        run &+= 1
        messenger.setStatuses([])
    }

    /// Sets the status for the current task, and sets it again whenever the task or its phase
    /// changes, not only when the strip appears or disappears, so the icon moves from progress
    /// to failed.
    private func observe(run: UInt64) {
        guard isRunning, self.run == run else { return }
        let status = withObservationTracking {
            transferStore.currentTask.map(Self.status(for:))
        } onChange: { [weak self] in
            // onChange runs before the change lands, so read the new value on the next turn.
            Task { @MainActor [weak self] in self?.observe(run: run) }
        }
        messenger.setStatuses(status.map { [$0] } ?? [])
    }

    static func status(for task: TransferTask) -> IslandStatus {
        let title: String
        let symbol: String
        var tone = IslandStatus.Tone.progress
        switch task.phase {
        case .failed:
            title = String(localized: "Transfer failed")
            symbol = "exclamationmark.octagon.fill"
            tone = .warning
        case .partiallySucceeded:
            title = String(localized: "Transfer completed with warnings")
            symbol = "exclamationmark.triangle.fill"
            tone = .warning
        case .targetAccepted, .delivered:
            title = String(localized: "Transfer complete")
            symbol = "checkmark.circle.fill"
        case .cancelled:
            title = String(localized: "Transfer cancelled")
            symbol = "xmark.circle"
        case .preparing, .receiving, .finalizing:
            title = String(localized: "Transferring content…")
            symbol = "arrow.up.arrow.down"
        }
        return IslandStatus(key: "transfer", title: title, systemImage: symbol, tone: tone,
                            announcesWhenRaised: false)
    }
}

@MainActor
@Observable
final class IslandModuleContainer {
    private(set) var registrations: [IslandModuleRegistration]
    private(set) var availability: [IslandModuleID: IslandModuleAvailability] = [:]
    private(set) var runningModuleIDs: Set<IslandModuleID> = []

    @ObservationIgnored private let messages: IslandMessageCenter

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
        // Before start(), so a status the module sets while starting is accepted.
        messages.moduleDidStart(moduleID)
        registration.runtime.start()
        availability[moduleID] = .available
    }

    private func stop(_ registration: IslandModuleRegistration) {
        guard runningModuleIDs.remove(registration.id) != nil else { return }
        registration.runtime.stop()
        // After stop(), so nothing the module sets while stopping outlives it.
        messages.moduleDidStop(registration.id)
        availability.removeValue(forKey: registration.id)
    }
}
