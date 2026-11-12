import Foundation
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime

@MainActor
final class ClaudeContextUsageEstimator: ContextUsageEstimating {
    let agent: AgentProviderKind = .claudeCode
    private let tokenEstimator: (String) -> Int
    private let contextUsageBuilder: ProviderTurnContextUsageBuilder

    init(
        tokenEstimator: @escaping (String) -> Int,
        contextUsageBuilder: @escaping ProviderTurnContextUsageBuilder
    ) {
        self.tokenEstimator = tokenEstimator
        self.contextUsageBuilder = contextUsageBuilder
    }

    @discardableResult
    func enqueueUserTurnEstimate(
        messageForProvider: String,
        session: AgentTabSession
    ) -> Int {
        let estimate = max(0, tokenEstimator(messageForProvider))
        session.pendingNonCodexUserInputTokenQueue.append(estimate)
        return estimate
    }

    @discardableResult
    func replaceNextQueuedUserTurnEstimate(
        messageForProvider: String,
        session: AgentTabSession
    ) -> Int? {
        guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
        let estimate = max(0, tokenEstimator(messageForProvider))
        session.pendingNonCodexUserInputTokenQueue[0] = estimate
        return estimate
    }

    func dequeueQueuedUserTurnEstimate(session: AgentTabSession) -> Int? {
        guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
        return session.pendingNonCodexUserInputTokenQueue.removeFirst()
    }

    func beginTurn(session: AgentTabSession, initialMessage: String) {
        let userTokens = dequeueQueuedUserTurnEstimate(session: session) ?? tokenEstimate(for: initialMessage)
        session.activeNonCodexTurnTokenAccumulator = AgentModeViewModel.NonCodexTurnTokenAccumulator(
            estimatedUserInputTokens: max(0, userTokens),
            estimatedToolInputTokens: 0,
            estimatedToolOutputTokens: 0
        )
        if userTokens > 0 {
            session.isDirty = true
        }
    }

    func addUserInputTokens(_ tokens: Int, session: AgentTabSession) {
        guard tokens > 0 else { return }
        var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
        accumulator.estimatedUserInputTokens += tokens
        session.activeNonCodexTurnTokenAccumulator = accumulator
        session.isDirty = true
    }

    func addToolInputPayload(_ payload: String?, session: AgentTabSession) {
        let tokens = tokenEstimate(for: payload)
        guard tokens > 0 else { return }
        var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
        accumulator.estimatedToolInputTokens += tokens
        session.activeNonCodexTurnTokenAccumulator = accumulator
        session.isDirty = true
    }

    func addToolOutputPayload(_ payload: String?, session: AgentTabSession) {
        let tokens = tokenEstimate(for: payload)
        guard tokens > 0 else { return }
        var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
        accumulator.estimatedToolOutputTokens += tokens
        session.activeNonCodexTurnTokenAccumulator = accumulator
        session.isDirty = true
    }

    @discardableResult
    func ingestUsageSignal(
        promptTokens: Int?,
        completionTokens _: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot? {
        let prompt = max(0, promptTokens ?? 0)
        let existing = session.codexContextUsage
        recordReportedCapacity(modelContextWindow, session: session)
        let resolvedWindow = Self.resolvedContextWindow(reported: modelContextWindow, session: session)
        let ceiling = Self.verifiedCapacity(reported: modelContextWindow, session: session)
        let contextUsed = normalizedContextUsedTokens(contextUsedTokens, modelContextWindow: ceiling) ?? 0
        // A report whose occupancy was rejected as impossible cannot vouch for its prompt count either.
        let occupancyRejected = (contextUsedTokens ?? 0) > 0 && contextUsed == 0

        // Record exact stream-derived context in the per-turn accumulator so
        // finalizeTurn can persist it without relying on session-wide state.
        if contextUsed > 0 {
            var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
            accumulator.observedContextUsedTokens = contextUsed
            session.activeNonCodexTurnTokenAccumulator = accumulator
        }

        let usedSignal: Int? = {
            if contextUsed > 0 {
                return contextUsed
            }
            // A billed prompt count cannot resolve an unknown post-compaction occupancy.
            if !occupancyRejected,
               !awaitsPostCompactionUsage(session: session),
               let prompt = normalizedContextUsedTokens(prompt, modelContextWindow: ceiling)
            {
                return prompt
            }
            return nil
        }()
        let carried = carriedUsage(existing, ceiling: ceiling)
        let resolvedUsed = usedSignal ?? carried.last
        guard resolvedUsed != nil || resolvedWindow != nil else { return nil }

        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedUsed ?? carried.total,
            awaitingPostCompactionUsage: contextUsed > 0 ? nil : existing?.awaitingPostCompactionUsage
        )
        return updateSnapshot(
            from: session.codexContextUsage,
            source: .claudeUsageEvent,
            confidence: contextUsed > 0 ? .exact : .bestEffort,
            session: session
        )
    }

    @discardableResult
    func ingestTurnFinalizationSignal(
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot? {
        let existing = session.codexContextUsage
        recordReportedCapacity(modelContextWindow, session: session)
        let resolvedWindow = Self.resolvedContextWindow(reported: modelContextWindow, session: session)
        let ceiling = Self.verifiedCapacity(reported: modelContextWindow, session: session)
        let resolvedContextUsed = normalizedContextUsedTokens(contextUsedTokens, modelContextWindow: ceiling) ?? 0
        // A count streamed before this report established the capacity may exceed it.
        let carried = carriedUsage(existing, ceiling: ceiling)
        let resolvedUsed = resolvedContextUsed > 0 ? resolvedContextUsed : carried.last
        guard resolvedUsed != nil || resolvedWindow != nil else { return nil }

        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedUsed ?? carried.total,
            awaitingPostCompactionUsage: resolvedContextUsed > 0 ? nil : existing?.awaitingPostCompactionUsage
        )
        return updateSnapshot(
            from: session.codexContextUsage,
            source: .turnFinalization,
            confidence: resolvedContextUsed > 0 ? .exact : .bestEffort,
            session: session
        )
    }

    func ingestStatusSignal(_ statusText: String?, session: AgentTabSession) {
        guard let statusText = statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !statusText.isEmpty
        else { return }
        let normalized = statusText.lowercased()
        guard normalized.contains("compacting context") else { return }
        session.contextCompactedAt = Date()
        _ = updateSnapshot(
            from: session.codexContextUsage,
            source: .compactionSignal,
            confidence: .bestEffort,
            session: session
        )
    }

    func ingestSystemSignal(_ systemText: String?, session: AgentTabSession) {
        guard let systemText = systemText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !systemText.isEmpty
        else { return }
        let normalized = systemText.lowercased()
        guard normalized.hasPrefix("context compacted") else { return }
        session.contextCompactedAt = Date()
        // compact_boundary reports pre_tokens, not the size of the compacted context.
        // Invalidate both ring fallbacks and this turn's pre-boundary observation while
        // retaining the model window and all historical billing/usage records.
        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: session.codexContextUsage?.modelContextWindow,
            lastTotalTokens: nil,
            totalTotalTokens: nil,
            awaitingPostCompactionUsage: true
        )
        // Persist the fence immediately: /compact can end without any billable turn usage.
        session.providerTokenUsageByTurn.append(AgentTokenUsagePersist(
            runID: session.runID,
            turnID: session.transcript.turns.last?.id,
            promptTokens: 0,
            completionTokens: 0,
            contextCompacted: true
        ))
        session.activeNonCodexTurnTokenAccumulator?.observedContextUsedTokens = nil
        session.isDirty = true
        _ = updateSnapshot(
            from: session.codexContextUsage,
            source: .compactionSignal,
            confidence: .bestEffort,
            session: session
        )
    }

    @discardableResult
    func finalizeTurn(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        session: AgentTabSession
    ) -> Bool {
        let prompt = max(0, promptTokens ?? 0)
        let completion = max(0, completionTokens ?? 0)
        let accumulator = session.activeNonCodexTurnTokenAccumulator
        let estimatedUser = accumulator?.estimatedUserInputTokens ?? 0
        let estimatedToolInput = accumulator?.estimatedToolInputTokens ?? 0
        let estimatedToolOutput = accumulator?.estimatedToolOutputTokens ?? 0
        let finalizedWindow = Self.resolvedContextWindow(reported: nil, session: session)
        let finalizedCeiling = Self.verifiedCapacity(reported: nil, session: session)
        let resolvedContextUsed = normalizedContextUsedTokens(
            contextUsedTokens,
            modelContextWindow: finalizedCeiling
        ) ?? 0
        let hasUsage = prompt > 0
            || completion > 0
            || estimatedUser > 0
            || estimatedToolInput > 0
            || estimatedToolOutput > 0
            || resolvedContextUsed > 0

        guard hasUsage else {
            if !session.providerTokenUsageByTurn.isEmpty,
               session.codexContextUsage == nil
            {
                session.codexContextUsage = contextUsageBuilder(
                    session.providerTokenUsageByTurn,
                    nil
                )
                _ = updateSnapshot(
                    from: session.codexContextUsage,
                    source: .persistedTurns,
                    confidence: .inferred,
                    session: session
                )
            }
            return false
        }

        session.activeNonCodexTurnTokenAccumulator = nil
        // Prefer the exact stream-observed context for this turn over any session-wide
        // display value. The previous fallback to session.codexContextUsage?.lastTotalTokens
        // caused previous-turn context leakage into later persisted rows.
        // The turn may have streamed this before its result established the capacity.
        let accumulatorContextUsed = normalizedContextUsedTokens(
            accumulator?.observedContextUsedTokens,
            modelContextWindow: finalizedCeiling
        ) ?? 0
        let persistedContextUsed = resolvedContextUsed > 0 ? resolvedContextUsed : (accumulatorContextUsed > 0 ? accumulatorContextUsed : 0)
        let usage = AgentTokenUsagePersist(
            runID: session.runID,
            turnID: session.transcript.turns.last?.id,
            promptTokens: prompt,
            completionTokens: completion,
            contextUsedTokens: persistedContextUsed > 0 ? persistedContextUsed : nil,
            estimatedUserInputTokens: estimatedUser,
            estimatedToolInputTokens: estimatedToolInput,
            estimatedToolOutputTokens: estimatedToolOutput
        )
        session.providerTokenUsageByTurn.append(usage)
        // Rebuild from persisted turns, but the builder only uses real Claude API values
        // (contextUsedTokens, promptTokens). If it returns nil (no real values in any turn),
        // preserve the existing codexContextUsage which may have been set by
        // ingestUsageSignal with actual data.
        let existingUsage = session.codexContextUsage
        // The persisted compaction fence stops the builder from reaching pre-boundary
        // occupancy. Rebuilding is safe even on later turns without a new measurement.
        // The builder bounds rows by the window it is given, so it receives the model's capacity;
        // the stored window stays the effective (possibly auto-compact) window.
        let rebuilt = contextUsageBuilder(
            session.providerTokenUsageByTurn,
            finalizedCeiling
        ).map { usage -> AgentContextUsage in
            var usage = usage
            usage.modelContextWindow = finalizedWindow
            return usage
        }
        if let rebuilt {
            session.codexContextUsage = rebuilt
        }
        _ = updateSnapshot(
            from: session.codexContextUsage,
            source: .turnFinalization,
            confidence: (rebuilt ?? existingUsage)?.lastTotalTokens != nil ? .bestEffort : .inferred,
            session: session
        )
        session.isDirty = true
        return true
    }

    /// Whether this estimator owns the provider's usage, and so its context window.
    static func estimatesUsage(for agent: AgentProviderKind) -> Bool {
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: true
        case .openCode, .cursor, .grokBuild, .antigravity, .devin, .codexExec: false
        }
    }

    /// Recomputes only the effective window, for example when runtime init reports a process's
    /// auto-compact window. Occupancy, compaction state, and snapshot provenance are kept, and no
    /// provider vouch is created: a changed window simply stops matching an earlier window vouch.
    @discardableResult
    func reconcileContextWindow(session: AgentTabSession) -> Bool {
        Self.reconcileContextWindow(session: session, createsUsage: true)
    }

    /// The shared window recompute. `createsUsage` is false for a provider or model switch, which
    /// only resizes usage that already exists rather than inventing a usage record.
    @discardableResult
    static func reconcileContextWindow(session: AgentTabSession, createsUsage: Bool) -> Bool {
        let window = resolvedContextWindow(reported: nil, session: session)
        var changed = false
        if var usage = session.codexContextUsage {
            if usage.modelContextWindow != window {
                usage.modelContextWindow = window
                session.codexContextUsage = usage
                changed = true
            }
        } else if createsUsage, let window {
            session.codexContextUsage = AgentContextUsage(modelContextWindow: window, lastTotalTokens: nil, totalTotalTokens: nil)
            changed = true
        }
        if var snapshot = session.contextUsageSnapshot, snapshot.window != window {
            snapshot.window = window
            let isEmpty = snapshot.used == nil && snapshot.window == nil && snapshot.compactedAt == nil
            session.contextUsageSnapshot = isEmpty ? nil : snapshot
            changed = true
        }
        return changed
    }

    func verifiedCapacity(reported: Int?, session: AgentTabSession) -> Int? {
        Self.verifiedCapacity(reported: reported, session: session)
    }

    /// The model's own capacity from verified sources: this report, the capacity stored for the
    /// selected provider and model, or the configured compatible backend. A stored effective window
    /// may be an auto-compact cap, so it is never treated as capacity. Unknown stays nil.
    static func verifiedCapacity(reported: Int?, session: AgentTabSession) -> Int? {
        if let reported, reported > 0 { return reported }
        return session.identityValidContextWindowCapacity ?? ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
            forRequestedModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        )
    }

    /// The effective window: the model's capacity capped by the process's auto-compact window. With
    /// a cap but no verified capacity, the model catalog sizes the window (never the ceiling).
    static func resolvedContextWindow(reported: Int?, session: AgentTabSession) -> Int? {
        let capacity = verifiedCapacity(reported: reported, session: session)
        guard let autoCompactWindow = session.activeClaudeAutoCompactWindowTokens else { return capacity }
        let modelWindow = capacity ?? AgentModel.resolvedModel(
            forRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        )?.contextWindowTokens
        return ClaudeCompatiblePluginAutoCompactWindow.effectiveWindow(modelWindow: modelWindow, autoCompactWindow: autoCompactWindow)
    }

    private func recordReportedCapacity(_ reported: Int?, session: AgentTabSession) {
        guard let reported, reported > 0 else { return }
        session.recordContextWindowCapacity(reported)
    }

    /// Stored figures carried into a new record, dropped when they exceed a now-known capacity.
    private func carriedUsage(_ usage: AgentContextUsage?, ceiling: Int?) -> (last: Int?, total: Int?) {
        (
            normalizedContextUsedTokens(usage?.lastTotalTokens, modelContextWindow: ceiling),
            normalizedContextUsedTokens(usage?.totalTotalTokens, modelContextWindow: ceiling)
        )
    }

    private func awaitsPostCompactionUsage(session: AgentTabSession) -> Bool {
        session.codexContextUsage?.awaitingPostCompactionUsage == true
    }

    private func normalizedContextUsedTokens(
        _ contextUsedTokens: Int?,
        modelContextWindow: Int?
    ) -> Int? {
        let normalized = max(0, contextUsedTokens ?? 0)
        guard normalized > 0 else { return nil }
        // An unknown window cannot reject a reading: a fixed fallback ceiling would discard
        // valid occupancy above it on larger-window models.
        if let modelContextWindow, modelContextWindow > 0, normalized > modelContextWindow {
            return nil
        }
        return normalized
    }

    private func tokenEstimate(for payload: String?) -> Int {
        max(0, tokenEstimator(payload ?? ""))
    }
}
