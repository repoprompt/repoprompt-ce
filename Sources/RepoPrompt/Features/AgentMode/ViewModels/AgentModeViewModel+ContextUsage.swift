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

    func ingestNonCodexTurnFinalization(promptTokens: Int?, completionTokens: Int?, contextUsedTokens: Int?, modelContextWindow: Int?, session: TabSession) {
        if usageRuntime.ingestNonCodexTurnFinalization(promptTokens: promptTokens, completionTokens: completionTokens, contextUsedTokens: contextUsedTokens, modelContextWindow: modelContextWindow, session: session) {
            scheduleSave(for: session)
        }
    }

    func dequeuePendingNonCodexUserTokens(for session: TabSession) -> Int? {
        usageRuntime.dequeuePendingNonCodexUserTokens(for: session)
    }

    func startNonCodexTurnAccountingIfNeeded(for session: TabSession, initialMessage: String) {
        if usageRuntime.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: initialMessage) {
            scheduleSave(for: session)
        }
    }

    nonisolated static func contextUsageFromClaudeProviderTokens(_ usage: [AgentTokenUsagePersist], modelContextWindow: Int?) -> AgentContextUsage? {
        AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: modelContextWindow)
    }
}
