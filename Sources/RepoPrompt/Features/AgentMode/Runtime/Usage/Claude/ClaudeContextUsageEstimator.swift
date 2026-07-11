import Foundation

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
        session: AgentModeViewModel.TabSession
    ) -> Int {
        let estimate = max(0, tokenEstimator(messageForProvider))
        session.pendingNonCodexUserInputTokenQueue.append(estimate)
        return estimate
    }

    @discardableResult
    func replaceNextQueuedUserTurnEstimate(
        messageForProvider: String,
        session: AgentModeViewModel.TabSession
    ) -> Int? {
        guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
        let estimate = max(0, tokenEstimator(messageForProvider))
        session.pendingNonCodexUserInputTokenQueue[0] = estimate
        return estimate
    }

    func dequeueQueuedUserTurnEstimate(session: AgentModeViewModel.TabSession) -> Int? {
        guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
        return session.pendingNonCodexUserInputTokenQueue.removeFirst()
    }

    func beginTurn(session: AgentModeViewModel.TabSession, initialMessage: String) {
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

    func addUserInputTokens(_ tokens: Int, session: AgentModeViewModel.TabSession) {
        guard tokens > 0 else { return }
        var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
        accumulator.estimatedUserInputTokens += tokens
        session.activeNonCodexTurnTokenAccumulator = accumulator
        session.isDirty = true
    }

    func addToolInputPayload(_ payload: String?, session: AgentModeViewModel.TabSession) {
        let tokens = tokenEstimate(for: payload)
        guard tokens > 0 else { return }
        var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
        accumulator.estimatedToolInputTokens += tokens
        session.activeNonCodexTurnTokenAccumulator = accumulator
        session.isDirty = true
    }

    func addToolOutputPayload(_ payload: String?, session: AgentModeViewModel.TabSession) {
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
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot? {
        let prompt = max(0, promptTokens ?? 0)
        let existing = session.codexContextUsage
        let resolvedWindow = modelContextWindow ?? existing?.modelContextWindow
        let contextUsed = ClaudeContextUsedTokensBound.normalizedReading(
            contextUsedTokens,
            canonicalWindow: resolvedWindow
        ) ?? 0

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
            if prompt > 0 {
                return prompt
            }
            return nil
        }()
        let resolvedUsed = usedSignal ?? existing?.lastTotalTokens
        guard resolvedUsed != nil || resolvedWindow != nil else { return nil }

        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            configuredContextWindow: session.claudeConfiguredContextWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedUsed ?? existing?.totalTotalTokens
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
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot? {
        let existing = session.codexContextUsage
        let resolvedWindow = modelContextWindow ?? existing?.modelContextWindow
        let resolvedContextUsed = ClaudeContextUsedTokensBound.normalizedReading(
            contextUsedTokens,
            canonicalWindow: resolvedWindow
        ) ?? 0
        let resolvedUsed = resolvedContextUsed > 0 ? resolvedContextUsed : existing?.lastTotalTokens
        guard resolvedUsed != nil || resolvedWindow != nil else { return nil }

        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            configuredContextWindow: session.claudeConfiguredContextWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedUsed ?? existing?.totalTotalTokens
        )
        return updateSnapshot(
            from: session.codexContextUsage,
            source: .turnFinalization,
            confidence: resolvedContextUsed > 0 ? .exact : .bestEffort,
            session: session
        )
    }

    func ingestStatusSignal(_ statusText: String?, session: AgentModeViewModel.TabSession) {
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

    func ingestSystemSignal(_ systemText: String?, session: AgentModeViewModel.TabSession) {
        guard let systemText = systemText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !systemText.isEmpty
        else { return }
        let normalized = systemText.lowercased()
        guard normalized.contains("context compacted") else { return }
        session.contextCompactedAt = Date()
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
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        let prompt = max(0, promptTokens ?? 0)
        let completion = max(0, completionTokens ?? 0)
        let accumulator = session.activeNonCodexTurnTokenAccumulator
        let estimatedUser = accumulator?.estimatedUserInputTokens ?? 0
        let estimatedToolInput = accumulator?.estimatedToolInputTokens ?? 0
        let estimatedToolOutput = accumulator?.estimatedToolOutputTokens ?? 0
        let resolvedContextUsed = ClaudeContextUsedTokensBound.normalizedReading(
            contextUsedTokens,
            canonicalWindow: session.codexContextUsage?.modelContextWindow
        ) ?? 0
        let hasUsage = prompt > 0
            || completion > 0
            || estimatedUser > 0
            || estimatedToolInput > 0
            || estimatedToolOutput > 0
            || resolvedContextUsed > 0

        guard hasUsage else {
            if !session.providerTokenUsageByTurn.isEmpty, session.codexContextUsage == nil {
                session.codexContextUsage = contextUsageBuilder(
                    session.providerTokenUsageByTurn,
                    nil,
                    session.claudeConfiguredContextWindow
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
        let accumulatorContextUsed = accumulator?.observedContextUsedTokens ?? 0
        let persistedContextUsed = resolvedContextUsed > 0 ? resolvedContextUsed : (accumulatorContextUsed > 0 ? accumulatorContextUsed : 0)
        let usage = AgentTokenUsagePersist(
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
        let rebuilt = contextUsageBuilder(
            session.providerTokenUsageByTurn,
            existingUsage?.modelContextWindow,
            session.claudeConfiguredContextWindow
        )
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

    private func updateSnapshot(
        from usage: AgentContextUsage?,
        source: ContextUsageSnapshotSource,
        confidence: ContextUsageSnapshotConfidence,
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot? {
        let next = ContextUsageSnapshot.fromAgentContextUsage(
            usage,
            source: source,
            confidence: confidence,
            compactedAt: session.contextCompactedAt
        )
        if session.contextUsageSnapshot != next {
            session.contextUsageSnapshot = next
            return next
        }
        return nil
    }

    private func tokenEstimate(for payload: String?) -> Int {
        max(0, tokenEstimator(payload ?? ""))
    }
}
