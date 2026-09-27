import Foundation

@MainActor
extension AgentModeViewModel {
    func nonCodexContextUsageEstimator(for agent: AgentProviderKind) -> (any ContextUsageEstimating)? {
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeContextUsageEstimator
        case .openCode, .cursor, .grokBuild, .antigravity, .devin:
            acpContextUsageEstimator
        case .codexExec:
            nil
        }
    }

    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: TabSession) {
        session.codexContextUsage = usage
        _ = codexContextUsageEstimator.ingestNativeContextUsage(usage, session: session)
        // A Codex report delivered after the tab switched provider is not the new provider's load.
        guard session.selectedAgent == .codexExec else { return }
        session.noteLiveContextUsageReport(
            contextUsedTokens: usage.lastTotalTokens,
            promptTokens: nil,
            modelContextWindow: usage.modelContextWindow
        )
    }

    /// Ingests one live usage report from a non-Codex provider stream and records which figures it
    /// vouches for, even when the stored snapshot came out unchanged. Returns whether the session's
    /// usage state changed.
    func ingestNonCodexUsageReport(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: TabSession
    ) -> Bool {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return false }
        let changed = estimator.ingestUsageSignal(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextUsedTokens: contextUsedTokens,
            modelContextWindow: modelContextWindow,
            session: session
        ) != nil
        session.noteLiveContextUsageReport(
            contextUsedTokens: contextUsedTokens,
            promptTokens: promptTokens,
            modelContextWindow: modelContextWindow
        )
        return changed
    }

    func refreshCodexContextUsageSnapshot(for session: TabSession) {
        _ = codexContextUsageEstimator.ingestNativeContextUsage(session.codexContextUsage, session: session)
    }

    /// Ingests a non-Codex provider's end-of-turn usage (`message_stop`), where Claude-compatible
    /// providers report the context window, then records which figures it vouches for. The result's
    /// aggregate billed prompt count is never treated as a context count.
    func ingestNonCodexTurnFinalization(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: TabSession
    ) {
        guard let estimator = nonCodexContextUsageEstimator(for: session.selectedAgent) else { return }
        // Whether the provider already reported occupancy this turn must be read before the
        // finalization consumes its per-turn marker.
        let heldOccupancy = estimator.hasOccupancyReportThisTurn(session: session)
        _ = estimator.ingestTurnFinalizationSignal(
            contextUsedTokens: contextUsedTokens,
            modelContextWindow: modelContextWindow,
            session: session
        )
        finalizeNonCodexTurnUsageIfNeeded(
            for: session,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextUsedTokens: contextUsedTokens
        )
        // An ACP turn that ended without its own `usage_update` occupancy report leaves any stored
        // count from an earlier turn outdated, and its billed count is ring-only (see
        // `observationContextLoad`), so the count vouch is withdrawn and no billed count takes one.
        // Vouch presence then always matches whether a count is exported, and its transitions
        // republish (a later `usage_update` confirming the same figure establishes a vouch).
        if session.selectedAgent.acpProviderID != nil, !heldOccupancy {
            session.withdrawContextCountVouch(notingWindow: modelContextWindow)
            return
        }
        // A billed prompt-call count is a different quantity than occupancy: when the estimator
        // held a live `usage_update` figure this turn, the billed report cannot disturb that
        // figure's vouch — vouch the figure the provider actually reported this turn. Without a
        // live occupancy report the billed report stands alone, vouch or withdraw. Note the vouch
        // call treats nil and non-positive inputs as no-ops — only a positive reported count or
        // window can vouch a figure or withdraw an existing vouch.
        let vouchedCount: Int? = heldOccupancy
            ? session.contextUsageSnapshot?.used
            : contextUsedTokens
        session.noteLiveContextUsageReport(
            contextUsedTokens: vouchedCount,
            promptTokens: nil,
            modelContextWindow: modelContextWindow
        )
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
