import Foundation

/// Grok Build session-update normalizer. grok 1.0.3 emits only standard ACP update kinds
/// inside the `session/update` envelope (verified live: agent_message_chunk,
/// agent_thought_chunk, user_message_chunk, tool_call, tool_call_update,
/// available_commands_update, session_info_update); its x.ai extension updates ride
/// separate `_x.ai/*` methods that never reach this normalizer. So v1 is a thin adapter:
/// terminal tool updates get the shared canonical durable-result shape, everything else
/// delegates to the default normalizer, and unknown variants are ignored there.
enum GrokBuildACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }

        switch sessionUpdate {
        case "tool_call", "tool_call_update":
            return ACPDefaultSessionUpdateNormalizer.normalize(
                ACPToolUpdateResultAdapter.adaptedTerminalToolUpdatePayload(payload, sessionUpdate: sessionUpdate),
                providerID: .grokBuild
            )
        default:
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }
    }
}
