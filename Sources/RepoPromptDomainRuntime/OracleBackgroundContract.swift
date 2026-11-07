import Foundation
import MCP
import RepoPromptShared

/// Approved opt-in vocabulary. Default send/read behavior and legacy errors remain separate.
package enum OracleBackgroundContract {
    package static let startDescription = "background=true starts grouped Oracle work across turns. Stop cancels it. Collect with oracle_chat_log op=\"collect\". No single-Oracle or background export."
    package static let cancelDescription = "op=\"cancel\" with both Oracle IDs cancels this session's call; collect checks cleanup."
    package static let collectDescription = "op=\"collect\" inspects this session's background calls without waiting: no IDs lists this process; Oracle IDs or chat_id returns progress and finished answers. After restart use saved IDs."
    package static let recoveryGuidance = "Collect without IDs after compaction; after restart use saved IDs."
    package static let promptQualification = "Background calls belong to this Agent session; collect or cancel them across turns."

    package static func schema(tool: String, extending input: Value) -> Value {
        guard case var .object(schema) = input, case var .object(properties)? = schema["properties"] else { return input }
        for key in ["oracle_group_id", "oracle_turn_id"] {
            properties[key] = .object(["type": .string("string"), "format": .string("uuid")])
        }
        if tool == MCPWindowToolName.askOracle {
            properties["background"] = .object(["type": .string("boolean"), "default": .bool(false)])
            properties["op"] = .object(["type": .string("string"), "enum": .array([.string("send"), .string("cancel")]), "default": .string("send")])
            schema.removeValue(forKey: "required")
        } else if tool == MCPWindowToolName.oracleChatLog {
            properties["op"] = .object(["type": .string("string"), "enum": .array([.string("read"), .string("collect")]), "default": .string("read")])
            properties["include_finished"] = .object(["type": .string("boolean"), "default": .bool(true)])
        } else { return input }
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    package enum ResultCode: String {
        case unsupported, busy, notFound = "not_found", interrupted, notRunning = "not_running", cancelling, limit, unavailable, empty
        package var message: String {
            switch self {
            case .unsupported: "Use app-backed Agent Mode with at least two Oracles and export_response=false, or use a blocking call."
            case .busy: "Oracle work is busy or stopping. Collect the returned handle, or wait and retry."
            case .notFound: "Oracle call not found for this session. Collect without IDs to list this process's calls."
            case .interrupted: "This Oracle call was interrupted. It cannot resume; start a new chat."
            case .notRunning: "This call is not running. Collect its saved result or interruption status."
            case .cancelling: "Cancellation requested. Collect to check cleanup."
            case .limit: "This session has 4 active Oracle calls. Wait or cancel one."
            case .unavailable: "Oracle output is unavailable for this turn. Retry the same handle; do not substitute an earlier answer."
            case .empty: "No matching Oracle calls in this process. After restart use saved IDs."
            }
        }

        package var status: String {
            switch self {
            case .unsupported, .limit: "refused"
            default: rawValue
            }
        }
    }

    package static func operation(_ args: [String: Value], read: Bool) throws -> String {
        guard let value = args["op"] else { return read ? "read" : "send" }
        guard let op = value.stringValue, (read ? ["read", "collect"] : ["send", "cancel"]).contains(op) else {
            throw invalid("op", expected: read ? "read or collect" : "send or cancel")
        }
        return op
    }

    package static func boolean(_ args: [String: Value], _ key: String, default fallback: Bool) throws -> Bool {
        guard let value = args[key] else { return fallback }
        guard let result = value.boolValue else { throw invalid(key, expected: "boolean") }
        return result
    }

    package static func uuid(_ args: [String: Value], _ key: String) throws -> UUID? {
        guard let value = args[key] else { return nil }
        guard let text = value.stringValue, text.count == 36, let id = UUID(uuidString: text) else { throw invalid(key, expected: "UUID string") }
        return id
    }

    package static func invalid(_ field: String, expected: String) -> MCPError {
        .invalidParams("Invalid \(field); expected \(expected).")
    }

    package static func invalidConstraint(_ constraint: String) -> MCPError {
        .invalidParams("Invalid Oracle arguments: \(constraint).")
    }

    package static func refuseHeadlessOptIn(tool: String, arguments: [String: Value]) throws {
        if tool == MCPWindowToolName.askOracle {
            let op = try operation(arguments, read: false)
            let background = try boolean(arguments, "background", default: false)
            if op == "cancel" || background {
                throw MCPError.invalidParams(ResultCode.unsupported.message)
            }
        } else if tool == MCPWindowToolName.oracleChatLog, try operation(arguments, read: true) == "collect" {
            throw MCPError.invalidParams(ResultCode.unsupported.message)
        }
    }
}
