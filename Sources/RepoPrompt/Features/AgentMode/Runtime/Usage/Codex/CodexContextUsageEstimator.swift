import Foundation

@MainActor
final class CodexContextUsageEstimator: ContextUsageEstimating {
    let agent: AgentProviderKind = .codexExec

    @discardableResult
    func enqueueUserTurnEstimate(
        messageForProvider _: String,
        session _: AgentTabSession
    ) -> Int {
        0
    }

    @discardableResult
    func replaceNextQueuedUserTurnEstimate(
        messageForProvider _: String,
        session _: AgentTabSession
    ) -> Int? {
        nil
    }

    func dequeueQueuedUserTurnEstimate(session _: AgentTabSession) -> Int? {
        nil
    }

    func beginTurn(session _: AgentTabSession, initialMessage _: String) {
        // Codex uses native token usage events.
    }

    func addUserInputTokens(_ tokens: Int, session _: AgentTabSession) {
        _ = tokens
    }

    func addToolInputPayload(_ payload: String?, session _: AgentTabSession) {
        _ = payload
    }

    func addToolOutputPayload(_ payload: String?, session _: AgentTabSession) {
        _ = payload
    }

    @discardableResult
    func ingestUsageSignal(
        promptTokens _: Int?,
        completionTokens _: Int?,
        contextUsedTokens _: Int?,
        modelContextWindow _: Int?,
        session _: AgentTabSession
    ) -> ContextUsageSnapshot? {
        nil
    }

    @discardableResult
    func ingestTurnFinalizationSignal(
        contextUsedTokens _: Int?,
        modelContextWindow _: Int?,
        session _: AgentTabSession
    ) -> ContextUsageSnapshot? {
        nil
    }

    func ingestStatusSignal(_ statusText: String?, session _: AgentTabSession) {
        _ = statusText
    }

    func ingestSystemSignal(_ systemText: String?, session _: AgentTabSession) {
        _ = systemText
    }

    @discardableResult
    func finalizeTurn(
        promptTokens _: Int?,
        completionTokens _: Int?,
        contextUsedTokens _: Int?,
        session _: AgentTabSession
    ) -> Bool {
        false
    }

    @discardableResult
    func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot? {
        let next = ContextUsageSnapshot.fromAgentContextUsage(
            usage,
            source: .codexNativeUsage,
            confidence: .exact
        )
        if session.contextUsageSnapshot != next {
            session.contextUsageSnapshot = next
            return next
        }
        return nil
    }
}
