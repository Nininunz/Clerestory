import Foundation
import XPC

enum LowPowerModeHelper {
    private static let service = "com.nininunz.Clerestory.LowPowerMode"
    private static let requirement = #"anchor apple generic and identifier "com.nininunz.Clerestory.LowPowerMode" and certificate leaf[subject.OU] = "8KB55P2YKQ""#

    static func toggle() async throws {
        let connection = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
            throw HelperError.unavailable
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "action", "toggle")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            xpc_connection_send_message_with_reply(connection, message, nil) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: HelperError.unavailable)
                    return
                }
                if xpc_dictionary_get_bool(reply, "success") {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HelperError.rejected)
                }
            }
        }
    }

    private enum HelperError: LocalizedError {
        case unavailable, rejected

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
