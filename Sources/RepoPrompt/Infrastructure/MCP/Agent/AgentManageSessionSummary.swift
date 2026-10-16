import Foundation
import MCP
import RepoPromptSettingsCore

/// Shared metadata rendering and state filtering for agent_manage session responses.
/// Keeps the public state aliases identical across listing, create, resume, and stop.
@MainActor
enum AgentManageSessionSummary {
    static func object(
        sessionID: UUID?,
        name: String,
        lastModified: Date,
        itemCount: Int,
        agentRaw: String?,
        modelRaw: String?,
        stateRaw: String?,
        isLive: Bool,
        parentSessionID: UUID? = nil,
        isMCPOriginated: Bool = false,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) -> [String: Value] {
        let publicState = publicSessionState(raw: stateRaw)
        var obj: [String: Value] = [
            "session_id": sessionID.map { .string($0.uuidString) } ?? .null,
            "name": .string(name),
            "last_modified": .string(AgentMCPToolHelpers.timestamp(lastModified)),
            "item_count": .int(itemCount),
            "state": publicState.map(Value.string) ?? .null,
            "is_live": .bool(isLive)
        ]
        if let stateRaw, let publicState,
           normalizedStateToken(stateRaw) != normalizedStateToken(publicState)
        {
            obj["raw_state"] = .string(stateRaw)
        }
        if agentRaw != nil || modelRaw != nil {
            var agent: [String: Value] = [
                "id": agentRaw.map(Value.string) ?? .null,
                "model": modelRaw.map(Value.string) ?? .null
            ]
            let effectiveModelParameterSelections = AgentMCPModelParameterSupport.effectiveSelections(
                modelParameterSelections,
                agentRaw: agentRaw,
                modelRaw: modelRaw
            )
            if !effectiveModelParameterSelections.isEmpty {
                agent["model_parameters"] = .array(
                    AgentMCPModelParameterSupport.selectionValues(effectiveModelParameterSelections)
                )
            }
            obj["agent"] = .object(agent)
        }
        if let parentSessionID {
            obj["parent_session_id"] = .string(parentSessionID.uuidString)
        }
        if isMCPOriginated {
            obj["is_mcp_originated"] = .bool(true)
        }
        return obj
    }

    static func matchesState(object: [String: Value], filter: String) -> Bool {
        let filterAliases = sessionStateAliases(for: filter)
        guard !filterAliases.isEmpty else { return false }
        let stateAliases = sessionStateAliases(for: object["state"]?.stringValue)
        let rawStateAliases = sessionStateAliases(for: object["raw_state"]?.stringValue)
        return !stateAliases.isDisjoint(with: filterAliases)
            || !rawStateAliases.isDisjoint(with: filterAliases)
    }

    private static func sessionStateAliases(for raw: String?) -> Set<String> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let compact = normalizedStateToken(raw)
        var aliases: Set<String> = [compact]
        if let publicState = publicSessionState(raw: raw) {
            aliases.insert(normalizedStateToken(publicState))
        }
        if aliases.contains(where: isWaitingStateToken) {
            aliases.formUnion([
                normalizedStateToken(AgentRunMCPSnapshot.Status.waitingForInput.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForUser.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForQuestion.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForApproval.rawValue)
            ])
        }
        return aliases
    }

    private static func publicSessionState(raw stateRaw: String?) -> String? {
        guard let stateRaw = stateRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !stateRaw.isEmpty else { return nil }
        if let runState = AgentSessionRunState(rawValue: stateRaw) {
            switch runState {
            case .waitingForUser, .waitingForQuestion, .waitingForApproval:
                return AgentRunMCPSnapshot.Status.waitingForInput.rawValue
            case .idle, .running, .completed, .cancelled, .failed:
                return runState.rawValue
            }
        }
        let compact = normalizedStateToken(stateRaw)
        if isWaitingStateToken(compact) {
            return AgentRunMCPSnapshot.Status.waitingForInput.rawValue
        }
        return stateRaw
    }

    private static func normalizedStateToken(_ state: String) -> String {
        state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func isWaitingStateToken(_ token: String) -> Bool {
        [
            normalizedStateToken(AgentRunMCPSnapshot.Status.waitingForInput.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForUser.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForQuestion.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForApproval.rawValue)
        ].contains(token)
    }
}
