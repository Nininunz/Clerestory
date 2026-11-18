import Foundation
import ServiceManagement

/// The minimal interface decoupled from ServiceManagement, making it easier to test without modifying
/// system login items.
@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginController.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The sole source of the 'launch at login' status.
///
/// Do not save the switch state separately to UserDefaults here: system login items in settings may be
/// revoked by the user at any time. Therefore, `SMAppService.mainApp.status` is the actual status. When
/// registration fails, retain the system status and provide error feedback to the settings page to avoid
/// UI showing enabled while the system is not actually effective.
@MainActor
@Observable
final class LaunchAtLoginController {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case unavailable
    }

    private(set) var status: Status = .notRegistered
    private(set) var errorMessage: String?

    /// `.requiresApproval` indicates the request is still registered, but blocked by system settings; the
    /// switch remains on, and an additional prompt is shown for user approval. This allows the user to
    /// still unregister by turning off the switch.
    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }
    var isAvailable: Bool { status != .unavailable }

    private let service: any LaunchAtLoginServicing

    convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        refresh()
    }

    func refresh() {
        let refreshedStatus = service.status
        if refreshedStatus != status {
            // The user may have already approved or revoked in system settings; once the state changes
            // genuinely, the previous registration error is outdated and should not be displayed anymore.
            errorMessage = nil
        }
        status = refreshedStatus
    }

    func setRequested(_ requested: Bool) {
        errorMessage = nil
        guard isAvailable else { return }
        do {
            if requested {
                guard !isRequested else { return }
                try service.register()
            } else {
                guard isRequested else { return }
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginController.Status {
        Self.map(service.status)
    }

    /// When `mainApp` is queried for the first time, there is no corresponding record in the Background
    /// Task Management database, and the system may return `.notFound`. This does not mean the main app
    /// cannot register; the first `register()` is used to create this record. Therefore, normalize it as
    /// 'not yet registered' to avoid UI disabling the switch before the user has a chance to register.
    static func map(_ status: SMAppService.Status) -> LaunchAtLoginController.Status {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notRegistered
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
