import Foundation
import MCP

package enum MCPPromptContextOperation: Equatable, Sendable {
    case snapshot
    case get
    case set
    case append
    case clear
    case export
    case listPresets
    case selectPreset
    case unknown(rawValue: String)

    package static func parse(
        toolName: String,
        arguments: [String: Value]
    ) -> MCPPromptContextOperation {
        let defaultOperation = toolName == "workspace_context" ? "snapshot" : "get"
        let normalized = (arguments["op"]?.stringValue ?? defaultOperation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return switch normalized {
        case "snapshot": .snapshot
        case "get": .get
        case "set": .set
        case "append": .append
        case "clear": .clear
        case "export": .export
        case "list_presets": .listPresets
        case "select_preset": .selectPreset
        default: .unknown(rawValue: normalized)
        }
    }

    package var rawValue: String {
        switch self {
        case .snapshot: "snapshot"
        case .get: "get"
        case .set: "set"
        case .append: "append"
        case .clear: "clear"
        case .export: "export"
        case .listPresets: "list_presets"
        case .selectPreset: "select_preset"
        case let .unknown(rawValue): rawValue
        }
    }
}
