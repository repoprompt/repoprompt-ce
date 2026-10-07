import CoreFoundation
import Foundation

/// Lossless typed JSON at the Codex transport boundary. Shared with the app adapter so
/// quota actors never exchange non-Sendable `[String: Any]` responses.
package enum CodexJSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    package func toAny() -> Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues { $0.toAny() }
        case let .array(value): value.map { $0.toAny() }
        case .null: NSNull()
        }
    }

    package static func from(_ value: Any) -> CodexJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dict as [String: Any]:
            var output: [String: CodexJSONValue] = [:]
            for (key, value) in dict {
                if let converted = CodexJSONValue.from(value) {
                    output[key] = converted
                }
            }
            return .object(output)
        case let array as [Any]:
            return .array(array.compactMap { CodexJSONValue.from($0) })
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

package struct CodexQuotaNotification {
    package let method: String
    package let params: [String: CodexJSONValue]

    package init(method: String, params: [String: CodexJSONValue]) {
        self.method = method
        self.params = params
    }
}

/// Only the account-read/notification operations quota needs. App composition owns the
/// real process client; owning-module tests inject a fake with the same lifecycle.
package protocol CodexQuotaAppServerClient: Sendable {
    func startIfNeeded() async throws
    func subscribeNotifications() async -> AsyncStream<CodexQuotaNotification>
    func request(method: String, params: [String: CodexJSONValue]?, timeout: TimeInterval?) async throws -> [String: CodexJSONValue]
    func stop() async
}
