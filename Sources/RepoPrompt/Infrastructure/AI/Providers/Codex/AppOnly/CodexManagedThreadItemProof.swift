import CoreFoundation
import Foundation

/// Required-field shapes and discriminants from bundled 0.149.0's experimental
/// ThreadReadResponse.json definitions.ThreadItem. This is an admission proof,
/// not a permissive transcript renderer. Unknown liveness fails closed.
enum CodexManagedThreadItemProof {
    private enum Shape { case string, array, object, any, unsignedInteger }

    private static let required: [String: [String: Shape]] = [
        "userMessage": ["content": .array], "hookPrompt": ["fragments": .array],
        "agentMessage": ["text": .string], "plan": ["text": .string], "reasoning": [:],
        "commandExecution": ["command": .string, "commandActions": .array, "cwd": .string, "status": .string],
        "fileChange": ["changes": .array, "status": .string],
        "mcpToolCall": ["arguments": .any, "server": .string, "tool": .string, "status": .string],
        "dynamicToolCall": ["arguments": .any, "tool": .string, "status": .string],
        "collabAgentToolCall": ["agentsStates": .object, "receiverThreadIds": .array, "senderThreadId": .string, "tool": .string, "status": .string],
        "subAgentActivity": ["agentPath": .string, "agentThreadId": .string, "kind": .string],
        "webSearch": ["query": .string], "imageView": ["path": .string],
        "sleep": ["durationMs": .unsignedInteger],
        "imageGeneration": ["result": .string, "status": .string],
        "enteredReviewMode": ["review": .string], "exitedReviewMode": ["review": .string],
        "contextCompaction": [:]
    ]

    static func hasActiveWork(_ item: [String: Any]) throws -> Bool {
        guard let id = item["id"] as? String, !id.isEmpty,
              let type = item["type"] as? String, let fields = required[type] else { throw failure }
        for (key, shape) in fields {
            guard let value = item[key], matches(value, shape: shape) else { throw failure }
        }
        switch type {
        case "userMessage":
            let inputs = try objects(item, key: "content")
            for input in inputs {
                guard let kind = input["type"] as? String else { throw failure }
                let fields: [String]
                switch kind {
                case "text": fields = ["text"]
                case "image", "audio": fields = ["url"]
                case "localImage", "localAudio": fields = ["path"]
                case "skill", "mention": fields = ["name", "path"]
                default: throw failure
                }
                guard fields.allSatisfy({ input[$0] is String }) else { throw failure }
            }
        case "hookPrompt":
            for fragment in try objects(item, key: "fragments") {
                guard fragment["hookRunId"] is String, fragment["text"] is String else { throw failure }
            }
        case "reasoning":
            for key in ["summary", "content"] where item[key] != nil {
                guard item[key] is [String] else { throw failure }
            }
        case "commandExecution":
            for action in try objects(item, key: "commandActions") {
                guard let kind = action["type"] as? String, ["read", "listFiles", "search", "unknown"].contains(kind),
                      action["command"] is String else { throw failure }
                if kind == "read", !(action["name"] is String && action["path"] is String) { throw failure }
            }
            return try activeStatus(item, allowed: ["inProgress", "completed", "failed", "declined"])
        case "fileChange":
            for change in try objects(item, key: "changes") {
                guard change["path"] is String, change["diff"] is String,
                      let kind = change["kind"] as? [String: Any], let type = kind["type"] as? String,
                      ["add", "delete", "update"].contains(type) else { throw failure }
            }
            return try activeStatus(item, allowed: ["inProgress", "completed", "failed", "declined"])
        case "mcpToolCall", "dynamicToolCall":
            return try activeStatus(item, allowed: ["inProgress", "completed", "failed"])
        case "collabAgentToolCall":
            guard item["receiverThreadIds"] is [String],
                  let tool = item["tool"] as? String, ["spawnAgent", "sendInput", "resumeAgent", "wait", "closeAgent"].contains(tool),
                  let states = item["agentsStates"] as? [String: [String: Any]] else { throw failure }
            var active = try activeStatus(item, allowed: ["inProgress", "completed", "failed"])
            for state in states.values {
                guard let status = state["status"] as? String,
                      ["pendingInit", "running", "interrupted", "completed", "errored", "shutdown", "notFound"].contains(status)
                else { throw failure }
                active = active || !["completed", "errored", "shutdown"].contains(status)
            }
            return active
        case "imageGeneration", "subAgentActivity":
            // The schema exposes arbitrary image status text and child activity
            // markers, not a terminal liveness proof. Do not invent semantics.
            throw failure
        default: break
        }
        return false
    }

    private static var failure: CodexManagedHTTPPolicy.Failure {
        .unsupportedConfiguration
    }

    private static func activeStatus(_ item: [String: Any], allowed: [String]) throws -> Bool {
        guard let status = item["status"] as? String, allowed.contains(status) else { throw failure }
        return status == "inProgress"
    }

    private static func objects(_ item: [String: Any], key: String) throws -> [[String: Any]] {
        guard let values = item[key] as? [[String: Any]] else { throw failure }
        return values
    }

    private static func matches(_ value: Any, shape: Shape) -> Bool {
        switch shape {
        case .string: return value is String
        case .array: return value is [Any]
        case .object: return value is [String: Any]
        case .any: return true
        case .unsignedInteger:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let double = number.doubleValue
            return double.isFinite && double >= 0 && double <= 9_007_199_254_740_991 && double.rounded(.towardZero) == double
        }
    }
}
