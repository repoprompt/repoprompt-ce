import Foundation
import RepoPromptAIContracts
import RepoPromptCodexProvider
import RepoPromptDomainRuntime

struct AgentPersistentBindingTransitionToken: Equatable {
    let tabID: UUID
    let sessionIdentity: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity?
    let transitionGeneration: UInt64
    let sourceItemsRevision: Int

    @MainActor
    func matches(_ session: AgentTabSession) -> Bool {
        session.tabID == tabID && ObjectIdentifier(session) == sessionIdentity
            && session.persistentSessionBindingIdentity == binding
            && session.bindingTransitionGeneration == transitionGeneration
            && session.sourceItemsRevision == sourceItemsRevision
    }
}

/// Applies a loaded payload to its exact runtime incarnation. Storage reads and optional
/// presentation/index publication are outside this synchronous commit; no UI object is needed.
@MainActor
enum AgentSessionHydrationRuntime {
    /// Evidence of a full field application, qualified to one binding. Callers finish
    /// synchronous provider repairs before publishing readiness through the existing authority.
    struct AppliedPayload {
        fileprivate let session: AgentTabSession
        fileprivate let binding: AgentSessionRestorationBindingToken

        @MainActor
        @discardableResult
        func commitReadiness() -> Bool {
            guard session.currentRestorationBindingToken == binding else { return false }
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            guard session.qualifiedRestorationReadiness.isAuthoritative else { return false }
            session.hasLoadedPersistedState = true
            return true
        }
    }

    struct Selection {
        let agent: AgentProviderKind
        let modelRaw: String
        let explicitReasoningEffortRaw: String?
    }

    static func selection(
        for payload: AgentSessionHydrationPayload,
        availability: AgentModelCatalog.AvailabilityContext,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]?
    ) -> Selection {
        let persisted = payload.persistedSession
        let agent = payload.normalizedSelection.agent
        var model = payload.normalizedSelection.modelRaw
        var effort: String?
        if agent == .codexExec,
           let raw = persisted.agentModel, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            model = AgentCodexSelectionPolicy.normalizedModelRaw(from: raw)
            effort = CodexReasoningEffort.parse(persisted.agentReasoningEffort)?.rawValue
                ?? CodexModelSpecifier(raw: raw).reasoningEffort?.rawValue
        }
        if !AgentModelCatalog.isValid(rawModel: model, for: agent, availability: availability, codexDynamicModels: codexDynamicModels) {
            model = AgentModelCatalog.defaultModelRaw(for: agent, availability: availability, codexDynamicModels: codexDynamicModels)
        }
        return .init(agent: agent, modelRaw: model, explicitReasoningEffortRaw: effort)
    }

    static func restoreLinkState(from persisted: AgentSession, to session: AgentTabSession) {
        session.oversight.autoWakeOnUpdates = persisted.autoWakeOnOversightUpdates
        session.oversight.autoWakeTargetSessionIDs = persisted.agentSessionLinkAutoWakeTargetSessionIDs
        session.oversight.routineWakeIntervalEnabled = persisted.routineWakeIntervalEnabled
        session.oversight.routineWakeIntervalSeconds = AgentSessionLinkRoutineWakeInterval.normalized(persisted.routineWakeIntervalSeconds)
        session.oversight.periodicIdleWakeEnabled = persisted.periodicIdleWakeEnabled
        session.oversight.periodicIdleWakeIntervalSeconds = AgentSessionLinkPeriodicWakeInterval.normalized(persisted.periodicIdleWakeIntervalSeconds)
    }

    static func restoreCodexMetadata(from persisted: AgentSession, to session: AgentTabSession) {
        if persisted.codexConversationID == nil || session.codexConversationID != persisted.codexConversationID || session.codexRolloutPath != persisted.codexRolloutPath {
            session.clearCodexConversationIdentity()
        }
        session.codexConversationID = persisted.codexConversationID
        session.codexRolloutPath = persisted.codexRolloutPath
        session.providerCleanupHandle = persisted.resolvedProviderCleanupHandle
        session.codexModel = persisted.codexModel
        session.codexReasoningEffort = persisted.codexReasoningEffort
        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: persisted.codexContextWindow,
            lastTotalTokens: persisted.codexLastTotalTokens,
            totalTotalTokens: persisted.codexTotalTotalTokens
        )
        if session.selectedAgent == .codexExec {
            session.codexNeedsReconnect = persisted.codexConversationID != nil || persisted.codexRolloutPath != nil
        }
    }

    @discardableResult
    static func apply(
        _ payload: AgentSessionHydrationPayload,
        to session: AgentTabSession,
        expected: AgentPersistentBindingTransitionToken,
        selection: Selection,
        codexPolicy: AgentCodexSelectionPolicy,
        indexedPlacement: AgentSessionIndexEntry?,
        usage: AgentSessionUsageRuntime
    ) -> AppliedPayload? {
        guard expected.matches(session),
              let binding = session.currentRestorationBindingToken,
              expected.binding?.sessionID == payload.sessionID,
              payload.persistedSession.id == payload.sessionID,
              expected.binding?.workspaceID.map({ $0 == payload.sourceWorkspaceID }) ?? true,
              payload.persistedSession.workspaceID.map({ $0 == payload.sourceWorkspaceID }) ?? true
        else { return nil }
        let persisted = payload.persistedSession
        session.setItemsSilently(payload.canonicalLiveItems, reason: .persistedSessionHydration)
        // Replacement may sanitize raw tool payloads. There is no suspension or competing
        // writer between it and this application of the matching prepared transcript.
        AgentSessionTranscriptRuntime.apply(payload.builtPresentation, to: session)
        session.hasSentFirstMessage = payload.transcript.turns.contains { $0.request != nil }
        session.parentSessionID = persisted.parentSessionID
        session.createdByOverseerSessionID = persisted.createdByOverseerSessionID
        // The index wins when placement changed while the payload was being read.
        session.organizationalParentID = indexedPlacement?.organizationalParentID ?? persisted.organizationalParentID
        session.delegationScopeID = indexedPlacement?.delegationScopeID ?? persisted.delegationScopeID
        session.isMCPOriginated = persisted.isMCPOriginated
        session.worktreeBindings = persisted.worktreeBindings
        session.worktreeMergeOperations = persisted.worktreeMergeOperations
        session.nextSequenceIndex = payload.transcript.nextSequenceIndex
        session.lastActivityAt = persisted.savedAt
        session.lastUserMessageAt = payload.lastUserMessageAt
        session.selectedAgent = selection.agent
        session.selectedModelRaw = selection.modelRaw
        session.acpModelParameterSelections = persisted.acpModelParameterSelections
        session.transcriptAnalyticsSnapshot.selectedAgent = selection.agent
        session.autoEditEnabled = persisted.autoEditEnabled
        restoreLinkState(from: persisted, to: session)
        if selection.agent == .claudeCode,
           let pinned = ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
               modelRaw: selection.modelRaw, agentKind: selection.agent,
               pinnedEffortRaw: persisted.agentReasoningEffort
                   ?? ClaudeModelSpecifier(raw: selection.modelRaw).explicitEffortLevel?.rawValue,
               isMCPOriginated: persisted.isMCPOriginated
           )
        {
            session.selectedReasoningEffortRaw = pinned.rawValue
        } else if selection.agent == .codexExec {
            session.selectedModelRaw = AgentCodexSelectionPolicy.normalizedModelRaw(from: selection.modelRaw)
            session.selectedReasoningEffortRaw = codexPolicy.reasoningEffort(
                modelRaw: selection.modelRaw, explicitRaw: selection.explicitReasoningEffortRaw
            )?.rawValue
        } else {
            session.selectedReasoningEffortRaw = nil
        }
        // A pending seed approves an exact provider/model tuple, not the catalog fallback.
        if persisted.pendingHandoffProviderSwitchDelivery != nil,
           let rawAgent = persisted.agentKind, let agent = AgentProviderKind(rawValue: rawAgent),
           let model = persisted.agentModel, !model.isEmpty
        {
            session.selectedAgent = agent
            session.selectedModelRaw = model
        }
        session.runState = payload.normalizedRunState
        session.providerSessionID = persisted.providerSessionID
        session.providerCleanupHandle = persisted.resolvedProviderCleanupHandle
        session.providerTokenUsageByTurn = persisted.providerTokenUsageByTurn
        session.automationTurnAudit = persisted.automationTurnAudit
        session.pendingHandoff = .init(
            payload: persisted.pendingHandoffPayload, createdAt: persisted.pendingHandoffCreatedAt,
            sourceItemID: persisted.pendingHandoffSourceItemID,
            defersProviderLockUntilSend: persisted.pendingHandoffDefersProviderLockUntilSend,
            isStagedForSend: false,
            executionLocationFailure: persisted.pendingHandoffExecutionLocationFailure,
            providerSwitchDelivery: persisted.pendingHandoffProviderSwitchDelivery
        )
        session.selfCompactState = persisted.selfCompactState ?? .init()
        session.selfCompactPersistenceWarning = persisted.selfCompactPersistenceWarning
        session.contextWindowCapacity = persisted.contextWindowCapacity
        session.claudeAutoCompactWindowTokens = nil
        restoreCodexMetadata(from: persisted, to: session)
        switch session.selectedAgent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            session.contextCompactedAt = session.providerTokenUsageByTurn.last(where: { $0.contextCompacted })?.timestamp
            if session.codexContextUsage?.lastTotalTokens == nil || session.contextCompactedAt != nil {
                let capacity = usage.claudeContextUsageEstimator.verifiedCapacity(reported: nil, session: session)
                let displayedWindow = session.codexContextUsage?.modelContextWindow ?? capacity
                if var rebuilt = AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(
                    session.providerTokenUsageByTurn, modelContextWindow: capacity
                ) {
                    rebuilt.modelContextWindow = displayedWindow
                    session.codexContextUsage = rebuilt
                } else if !session.providerTokenUsageByTurn.isEmpty, let displayedWindow {
                    session.codexContextUsage = AgentContextUsage(modelContextWindow: displayedWindow, lastTotalTokens: nil, totalTotalTokens: nil)
                } else {
                    session.codexContextUsage = nil
                }
            }
        case .codexExec, .openCode, .cursor, .grokBuild, .antigravity, .devin:
            break
        }
        session.contextUsageSnapshot = ContextUsageSnapshot.fromAgentContextUsage(
            session.codexContextUsage, source: .persistedTurns,
            confidence: session.codexContextUsage?.lastTotalTokens != nil ? .bestEffort : .inferred,
            compactedAt: session.contextCompactedAt
        )
        if payload.needsReloadMigrationSave { session.isDirty = true }
        session.selectedClaudeEffortRaw = session.selectedAgent.usesClaudeTooling ? persisted.agentReasoningEffort : nil
        // No suspension separates currency verification and the full field application.
        // The caller retains this proof while completing synchronous provider repairs.
        return AppliedPayload(session: session, binding: binding)
    }
}
