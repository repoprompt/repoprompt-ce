import Foundation

@MainActor
extension AgentModeViewModel {
    func nonCodexContextUsageEstimator(for agent: AgentProviderKind) -> (any ContextUsageEstimating)? {
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeContextUsageEstimator
        case .codexExec, .openCode, .cursor, .grokBuild:
            nil
        }
    }

    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: TabSession) {
        session.codexContextUsage = usage
        _ = codexContextUsageEstimator.ingestNativeContextUsage(usage, session: session)
    }

    func refreshCodexContextUsageSnapshot(for session: TabSession) {
        _ = codexContextUsageEstimator.ingestNativeContextUsage(session.codexContextUsage, session: session)
    }

    func clearContextUsageSnapshot(for session: TabSession) {
        session.contextUsageSnapshot = nil
        session.contextCompactedAt = nil
    }

    func dequeuePendingNonCodexUserTokens(for session: TabSession) -> Int? {
        guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
        return session.pendingNonCodexUserInputTokenQueue.removeFirst()
    }

    func startNonCodexTurnAccountingIfNeeded(for session: TabSession, initialMessage: String) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        if session.activeNonCodexTurnTokenAccumulator != nil {
            finalizeNonCodexTurnUsageIfNeeded(for: session, promptTokens: nil, completionTokens: nil, contextUsedTokens: nil)
        }
        estimator.beginTurn(session: session, initialMessage: initialMessage)
    }

    func addUserInputTokensToActiveNonCodexTurn(_ tokens: Int, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addUserInputTokens(tokens, session: session)
    }

    func addToolInputTokens(_ payload: String?, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addToolInputPayload(payload, session: session)
    }

    func addToolOutputTokens(_ payload: String?, for session: TabSession) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        estimator.addToolOutputPayload(payload, session: session)
    }

    func finalizeNonCodexTurnUsageIfNeeded(
        for session: TabSession,
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?
    ) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        let didAppend = estimator.finalizeTurn(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextUsedTokens: contextUsedTokens,
            session: session
        )
        if didAppend {
            scheduleSave(for: session.tabID)
        }
    }

    nonisolated static func contextUsageFromClaudeProviderTokens(
        _ usage: [AgentTokenUsagePersist],
        modelContextWindow: Int?
    ) -> AgentContextUsage? {
        guard !usage.isEmpty else { return nil }
        let defaultClaudeContextWindow = 200_000
        let maxContextTokens = max(1, modelContextWindow ?? defaultClaudeContextWindow)
        // Only trust exact stream-derived context snapshots (contextUsedTokens).
        // Do NOT fall back to promptTokens — those are billed-turn aggregates that
        // include internal tool sub-steps and cause inflated context estimates.
        let latestContextUsed = usage.reversed().compactMap { turn -> Int? in
            if let contextUsed = turn.contextUsedTokens,
               contextUsed > 0,
               contextUsed <= maxContextTokens
            {
                return contextUsed
            }
            return nil
        }.first
        if let latestContextUsed {
            return AgentContextUsage(
                modelContextWindow: modelContextWindow,
                lastTotalTokens: latestContextUsed,
                totalTotalTokens: latestContextUsed
            )
        }
        guard modelContextWindow != nil else { return nil }
        return AgentContextUsage(
            modelContextWindow: modelContextWindow,
            lastTotalTokens: nil,
            totalTotalTokens: nil
        )
    }
}
