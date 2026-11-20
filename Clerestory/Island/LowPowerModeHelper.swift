import Foundation
import XPC

enum LowPowerModeHelper {
    private static let service = "com.nininunz.Clerestory.LowPowerMode"
    private static let requirement = #"anchor apple generic and identifier "com.nininunz.Clerestory.LowPowerMode" and certificate leaf[subject.OU] = "8KB55P2YKQ""#

    /// The helper package attached to the latest GitHub release.
    static let downloadURL = URL(string: "https://github.com/Nininunz/Clerestory/releases/latest/download/ClerestoryLowPowerMode.pkg")!
    /// System Settings → Battery, which has macOS's own Low Power Mode control.
    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    /// System Settings → General → Login Items & Extensions, where the helper is allowed to run.
    static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    static func toggle() async throws {
        guard try await send(action: "toggle") else { throw HelperError.rejected }
    }

    /// Whether the helper is installed, allowed to run, and accepts this app's signature.
    /// The helper answers any request but only acts on "toggle", so this changes nothing.
    static func isAvailable() async -> Bool {
        (try? await send(action: "status")) != nil
    }

    /// Returns the helper's "success" reply, or throws `unavailable` when it can't be reached.
    private static func send(action: String) async throws -> Bool {
        let connection = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
            throw HelperError.unavailable
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "action", action)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            xpc_connection_send_message_with_reply(connection, message, nil) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: HelperError.unavailable)
                    return
                }
                continuation.resume(returning: xpc_dictionary_get_bool(reply, "success"))
            }
        }
    }

    enum HelperError: LocalizedError {
        /// The helper isn't installed, isn't allowed to run, or doesn't match the app's signature.
        case unavailable
        case rejected

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "The Low Power Mode helper is unavailable. Install it, and allow Clerestory in System Settings under Login Items & Extensions.")
            case .rejected:
                String(localized: "Could not change Low Power Mode for the active power source.")
            }
        }
    }
}
