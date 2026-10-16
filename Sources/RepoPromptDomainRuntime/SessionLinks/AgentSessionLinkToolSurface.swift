import Foundation
import MCP

/// Catalog projection only. Exact-link authority and operation admission remain with their owners.
package enum AgentSessionLinkToolSurface: Hashable {
    case full
    case overseenOnly

    /// No exact Agent route (including external/headless callers) retains the legacy definition.
    /// A later session-local activation may select `.full` without changing link authority.
    package init(hasAnyActiveLink: Bool, hasActiveOutboundLink: Bool) {
        self = hasAnyActiveLink && !hasActiveOutboundLink ? .overseenOnly : .full
    }

    private static let overseenOperations: Set<String> = [
        "set_waiting_on", "request_attention", "create_lane"
    ]
    private static let overseenFields: Set<String> = [
        "op", "summary", "clear", "observer_session_id", "idempotency_key", "role", "model_id",
        "session_name", "workspace", "message", "workflow_id", "workflow_name"
    ]

    package func project(_ definition: MCPDomainToolDefinition) -> MCPDomainToolDefinition {
        guard self == .overseenOnly, definition.name == MCPWindowToolName.agentSessionLink,
              case var .object(schema) = definition.inputSchema,
              case let .object(fullProperties)? = schema["properties"]
        else { return definition }

        var properties = fullProperties.filter { Self.overseenFields.contains($0.key) }
        if case var .object(op)? = properties["op"], case let .array(operations)? = op["enum"] {
            op["enum"] = .array(operations.filter { Self.overseenOperations.contains($0.stringValue ?? "") })
            properties["op"] = .object(op)
        }
        for (name, value) in properties {
            guard case var .object(field) = value, let description = field["description"]?.stringValue else { continue }
            // Canonical bracket tags list applicable operations. Retain only offered tags, without
            // copying types or creation-field prose into a second schema authority.
            if description.hasPrefix("["), let end = description.firstIndex(of: "]") {
                let tags = description[description.index(after: description.startIndex) ..< end]
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { Self.overseenOperations.contains($0) }
                field["description"] = .string("[\(tags.joined(separator: ", "))]" + description[description.index(after: end)...])
            }
            // The canonical clear field also describes the hidden snooze operation.
            if name == "clear" {
                field["description"] = .string("[set_waiting_on] Clear your waiting declaration; exclusive with summary.")
            }
            properties[name] = .object(field)
        }
        schema["properties"] = .object(properties)
        schema["description"] = .string(
            "set_waiting_on: summary or clear:true. request_attention: observer_session_id?. "
                + "create_lane: idempotency_key; role or model_id, not both; session_name?, workspace?, message?, "
                + "workflow_id or workflow_name (with message)."
        )
        return MCPDomainToolDefinition(
            name: definition.name,
            description: "Declare what you are waiting on, ask a linked overseer for attention, or create a lane. Attention grants no authority.",
            inputSchema: .object(schema),
            annotations: definition.annotations,
            isEnabledByDefault: definition.isEnabledByDefault
        )
    }
}
