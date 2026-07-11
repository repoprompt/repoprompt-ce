import Foundation

enum ContextUsageSnapshotSource: String, Codable, Equatable {
    case claudeUsageEvent
    case geminiUsageEvent
    case codexNativeUsage
    case turnFinalization
    case persistedTurns
    case compactionSignal
}

enum ContextUsageSnapshotConfidence: String, Codable, Equatable {
    case exact
    case bestEffort
    case inferred
}

struct ContextUsageSnapshot: Codable, Equatable {
    var used: Int?
    var window: Int?
    var confidence: ContextUsageSnapshotConfidence
    var source: ContextUsageSnapshotSource
    var compactedAt: Date?
}

enum AgentContextWindowDenominator {
    static func effectiveContextWindowTokens(
        configured: Int?,
        canonical: Int?,
        fallback: Int
    ) -> Int {
        if let configured, let canonical {
            return min(configured, canonical)
        }
        if let configured {
            return configured
        }
        if let canonical {
            return canonical
        }
        return fallback
    }
}

extension ContextUsageSnapshot {
    static func fromAgentContextUsage(
        _ usage: AgentContextUsage?,
        source: ContextUsageSnapshotSource,
        confidence: ContextUsageSnapshotConfidence,
        compactedAt: Date? = nil
    ) -> ContextUsageSnapshot? {
        let used = usage?.lastTotalTokens
        let window = usage?.modelContextWindow
        guard used != nil || window != nil || compactedAt != nil else { return nil }
        return ContextUsageSnapshot(
            used: used,
            window: window,
            confidence: confidence,
            source: source,
            compactedAt: compactedAt
        )
    }
}

typealias ProviderTurnContextUsageBuilder = (
    _ turns: [AgentTokenUsagePersist],
    _ modelContextWindow: Int?,
    _ configuredContextWindow: Int?
) -> AgentContextUsage?

@MainActor
protocol ContextUsageEstimating: AnyObject {
    var agent: AgentProviderKind { get }

    @discardableResult
    func enqueueUserTurnEstimate(
        messageForProvider: String,
        session: AgentModeViewModel.TabSession
    ) -> Int

    @discardableResult
    func replaceNextQueuedUserTurnEstimate(
        messageForProvider: String,
        session: AgentModeViewModel.TabSession
    ) -> Int?

    func dequeueQueuedUserTurnEstimate(session: AgentModeViewModel.TabSession) -> Int?
    func beginTurn(session: AgentModeViewModel.TabSession, initialMessage: String)
    func addUserInputTokens(_ tokens: Int, session: AgentModeViewModel.TabSession)
    func addToolInputPayload(_ payload: String?, session: AgentModeViewModel.TabSession)
    func addToolOutputPayload(_ payload: String?, session: AgentModeViewModel.TabSession)

    @discardableResult
    func ingestUsageSignal(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot?

    @discardableResult
    func ingestTurnFinalizationSignal(
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot?

    func ingestStatusSignal(_ statusText: String?, session: AgentModeViewModel.TabSession)
    func ingestSystemSignal(_ systemText: String?, session: AgentModeViewModel.TabSession)

    @discardableResult
    func finalizeTurn(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        session: AgentModeViewModel.TabSession
    ) -> Bool

    @discardableResult
    func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot?
}

extension ContextUsageEstimating {
    @discardableResult
    func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session _: AgentModeViewModel.TabSession
    ) -> ContextUsageSnapshot? {
        _ = usage
        return nil
    }
}
