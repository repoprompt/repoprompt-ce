import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Presentation callers forward accounting to the runtime and schedule saves only when a durable
/// turn report was appended. The runtime can perform all accounting without constructing this VM.
@MainActor
extension AgentModeViewModel {
    var claudeContextUsageEstimator: ClaudeContextUsageEstimator {
        usageRuntime.claudeContextUsageEstimator
    }

    var acpContextUsageEstimator: ACPContextUsageEstimator {
        usageRuntime.acpContextUsageEstimator
    }

    func nonCodexContextUsageEstimator(for agent: AgentProviderKind) -> (any ContextUsageEstimating)? {
        usageRuntime.nonCodexContextUsageEstimator(for: agent)
    }

    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: TabSession) {
        usageRuntime.applyCodexNativeContextUsage(usage, session: session)
    }

    func ingestNonCodexUsageReport(promptTokens: Int?, completionTokens: Int?, contextUsedTokens: Int?, modelContextWindow: Int?, session: TabSession) -> Bool {
        usageRuntime.ingestNonCodexUsageReport(promptTokens: promptTokens, completionTokens: completionTokens, contextUsedTokens: contextUsedTokens, modelContextWindow: modelContextWindow, session: session)
    }

    func refreshCodexContextUsageSnapshot(for session: TabSession) {
        usageRuntime.refreshCodexContextUsageSnapshot(for: session)
    }

    func ingestNonCodexTurnFinalization(promptTokens: Int?, completionTokens: Int?, contextUsedTokens: Int?, modelContextWindow: Int?, session: TabSession) {
        if usageRuntime.ingestNonCodexTurnFinalization(promptTokens: promptTokens, completionTokens: completionTokens, contextUsedTokens: contextUsedTokens, modelContextWindow: modelContextWindow, session: session) {
            persistenceRuntime.scheduleSave(for: session)
        }
    }

    func clearContextUsageSnapshot(for session: TabSession) {
        usageRuntime.clearContextUsageSnapshot(for: session)
    }

    func dequeuePendingNonCodexUserTokens(for session: TabSession) -> Int? {
        usageRuntime.dequeuePendingNonCodexUserTokens(for: session)
    }

    func startNonCodexTurnAccountingIfNeeded(for session: TabSession, initialMessage: String) {
        if usageRuntime.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: initialMessage) {
            persistenceRuntime.scheduleSave(for: session)
        }
    }

    func addUserInputTokensToActiveNonCodexTurn(_ tokens: Int, for session: TabSession) {
        usageRuntime.addUserInputTokensToActiveNonCodexTurn(tokens, for: session)
    }

    func addToolInputTokens(_ payload: String?, for session: TabSession) {
        usageRuntime.addToolInputTokens(payload, for: session)
    }

    func addToolOutputTokens(_ payload: String?, for session: TabSession) {
        usageRuntime.addToolOutputTokens(payload, for: session)
    }

    func finalizeNonCodexTurnUsageIfNeeded(for session: TabSession, promptTokens: Int?, completionTokens: Int?, contextUsedTokens: Int?) {
        if usageRuntime.finalizeNonCodexTurnUsageIfNeeded(for: session, promptTokens: promptTokens, completionTokens: completionTokens, contextUsedTokens: contextUsedTokens) {
            persistenceRuntime.scheduleSave(for: session)
        }
    }

    nonisolated static func contextUsageFromClaudeProviderTokens(_ usage: [AgentTokenUsagePersist], modelContextWindow: Int?) -> AgentContextUsage? {
        AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: modelContextWindow)
    }
}
