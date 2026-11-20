import CryptoKit
import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Frozen payload construction and configured-creation stamps. Provider coordinators and
/// presentation objects do not participate in serializing a session's owned state.
@MainActor
enum AgentSessionPayloadBuilder {
    static func makePayload(
        session: AgentTabSession, sessionID: UUID, workspaceID: UUID,
        name: String, snapshot: AgentPersistableTranscriptSnapshot
    ) -> AgentSession {
        var agentSession = AgentSession(
            id: sessionID,
            workspaceID: workspaceID,
            composeTabID: session.tabID,
            name: name,
            items: [],
            transcript: snapshot.transcript,
            itemCount: snapshot.canonicalVisibleRowCount,
            transcriptProjectionCounts: snapshot.projectionCounts,
            lastUserMessageAt: snapshot.lastUserMessageAt,
            agentKind: session.selectedAgent.rawValue,
            agentModel: session.selectedModelRaw,
            agentReasoningEffort: session.persistedReasoningEffortRaw,
            acpModelParameterSelections: session.acpModelParameterSelections,
            lastRunState: session.runState.rawValue,
            providerSessionID: session.providerSessionID,
            providerCleanupHandle: ProviderConversationCleanupHandle.resolved(
                provider: session.selectedAgent.rawValue,
                explicit: session.providerCleanupHandle,
                providerSessionID: session.providerSessionID,
                codexConversationID: session.codexConversationID,
                codexRolloutPath: session.codexRolloutPath
            ),
            autoEditEnabled: session.autoEditEnabled,
            autoWakeOnOversightUpdates: session.oversight.autoWakeOnUpdates,
            agentSessionLinkAutoWakeTargetSessionIDs: session.oversight.autoWakeTargetSessionIDs,
            routineWakeIntervalEnabled: session.oversight.routineWakeIntervalEnabled,
            routineWakeIntervalSeconds: session.oversight.routineWakeIntervalSeconds,
            periodicIdleWakeEnabled: session.oversight.periodicIdleWakeEnabled,
            periodicIdleWakeIntervalSeconds: session.oversight.periodicIdleWakeIntervalSeconds,
            providerTokenUsageByTurn: session.providerTokenUsageByTurn,
            automationTurnAudit: session.automationTurnAudit,
            parentSessionID: session.parentSessionID,
            createdByOverseerSessionID: session.createdByOverseerSessionID,
            organizationalParentID: session.organizationalParentID,
            delegationScopeID: session.delegationScopeID,
            pendingHandoffProviderSwitchDelivery: session.pendingHandoff.providerSwitchDelivery,
            pendingHandoffPayload: session.pendingHandoff.payload,
            pendingHandoffCreatedAt: session.pendingHandoff.createdAt,
            pendingHandoffSourceItemID: session.pendingHandoff.sourceItemID,
            pendingHandoffDefersProviderLockUntilSend: session.pendingHandoff.defersProviderLockUntilSend,
            pendingHandoffExecutionLocationFailure: session.pendingHandoff.executionLocationFailure,
            selfCompactState: session.selfCompactState.active == nil && session.selfCompactState.latest == nil
                ? nil : session.selfCompactState,
            isMCPOriginated: session.isMCPOriginated,
            worktreeBindings: session.worktreeBindings,
            worktreeMergeOperations: session.worktreeMergeOperations
        )
        applyCodexPersistence(from: session, to: &agentSession)
        return agentSession
    }

    /// Freeze the actual initial payload. Write bookkeeping is excluded; unordered UUID targets
    /// are normalized. The receipt pins this payload; post-write checks separately cover runtime
    /// configuration and the existing transcript/persistence source revisions.
    static func creationConfigurationStamp(for payload: AgentSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var object = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any] else {
            throw MCPError.internalError("The prepared session could not be encoded as a configuration object.")
        }
        object.removeValue(forKey: "savedAt")
        object.removeValue(forKey: "fileURL")
        if let targets = object["agentSessionLinkAutoWakeTargetSessionIDs"] as? [String] {
            object["agentSessionLinkAutoWakeTargetSessionIDs"] = targets.sorted()
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Data(SHA256.hash(data: canonical))
    }

    /// Source revision fences protect the transcript. Explicitly reread persisted configuration
    /// after the writer awaits, since ordinary UI property setters do not all advance that revision.
    static func refreshCreationConfiguration(from session: AgentTabSession, name: String, payload: inout AgentSession) {
        payload.name = name
        payload.agentKind = session.selectedAgent.rawValue
        payload.agentModel = session.selectedModelRaw
        payload.agentReasoningEffort = session.persistedReasoningEffortRaw
        payload.acpModelParameterSelections = ACPModelParameterSelection.normalized(session.acpModelParameterSelections)
        payload.lastRunState = session.runState.rawValue
        payload.providerSessionID = session.providerSessionID
        payload.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
            provider: session.selectedAgent.rawValue, explicit: session.providerCleanupHandle,
            providerSessionID: session.providerSessionID, codexConversationID: session.codexConversationID,
            codexRolloutPath: session.codexRolloutPath
        )
        payload.autoEditEnabled = session.autoEditEnabled
        payload.autoWakeOnOversightUpdates = session.oversight.autoWakeOnUpdates
        payload.agentSessionLinkAutoWakeTargetSessionIDs = session.oversight.autoWakeTargetSessionIDs
        payload.routineWakeIntervalEnabled = session.oversight.routineWakeIntervalEnabled
        payload.routineWakeIntervalSeconds = AgentSessionLinkRoutineWakeInterval.normalized(session.oversight.routineWakeIntervalSeconds)
        payload.periodicIdleWakeEnabled = session.oversight.periodicIdleWakeEnabled
        payload.periodicIdleWakeIntervalSeconds = AgentSessionLinkPeriodicWakeInterval.normalized(session.oversight.periodicIdleWakeIntervalSeconds)
        payload.parentSessionID = session.parentSessionID
        payload.createdByOverseerSessionID = session.createdByOverseerSessionID
        payload.organizationalParentID = session.organizationalParentID
        payload.delegationScopeID = session.delegationScopeID
        payload.isMCPOriginated = session.isMCPOriginated
        payload.worktreeBindings = session.worktreeBindings
        payload.worktreeMergeOperations = session.worktreeMergeOperations
        payload.pendingHandoffProviderSwitchDelivery = session.pendingHandoff.providerSwitchDelivery
        payload.pendingHandoffPayload = session.pendingHandoff.payload
        payload.pendingHandoffCreatedAt = session.pendingHandoff.createdAt
        payload.pendingHandoffSourceItemID = session.pendingHandoff.sourceItemID
        payload.pendingHandoffDefersProviderLockUntilSend = session.pendingHandoff.defersProviderLockUntilSend
        payload.pendingHandoffExecutionLocationFailure = session.pendingHandoff.executionLocationFailure
        applyCodexPersistence(from: session, to: &payload)
    }

    static func applyCodexPersistence(
        from session: AgentTabSession,
        to agentSession: inout AgentSession
    ) {
        agentSession.codexConversationID = session.codexConversationID
        agentSession.codexRolloutPath = session.codexRolloutPath
        agentSession.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
            provider: session.selectedAgent.rawValue,
            explicit: session.providerCleanupHandle,
            providerSessionID: session.providerSessionID,
            codexConversationID: session.codexConversationID,
            codexRolloutPath: session.codexRolloutPath
        )
        agentSession.codexModel = session.codexModel
        agentSession.codexReasoningEffort = session.codexReasoningEffort
        agentSession.codexContextWindow = session.codexContextUsage?.modelContextWindow
        agentSession.contextWindowCapacity = session.contextWindowCapacity
        agentSession.codexLastTotalTokens = session.codexContextUsage?.lastTotalTokens
        agentSession.codexTotalTotalTokens = session.codexContextUsage?.totalTotalTokens
    }
}

struct AgentPersistableTranscriptSnapshot {
    let transcript: AgentTranscript
    let projectionCounts: AgentTranscriptProjectionCounts
    let canonicalVisibleRowCount: Int
    let lastUserMessageAt: Date?
}
