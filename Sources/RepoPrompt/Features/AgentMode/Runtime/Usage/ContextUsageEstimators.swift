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

typealias ProviderTurnContextUsageBuilder = (_ turns: [AgentTokenUsagePersist], _ modelContextWindow: Int?) -> AgentContextUsage?

@MainActor
protocol ContextUsageEstimating: AnyObject {
    var agent: AgentProviderKind { get }

    @discardableResult
    func enqueueUserTurnEstimate(
        messageForProvider: String,
        session: AgentTabSession
    ) -> Int

    @discardableResult
    func replaceNextQueuedUserTurnEstimate(
        messageForProvider: String,
        session: AgentTabSession
    ) -> Int?

    func dequeueQueuedUserTurnEstimate(session: AgentTabSession) -> Int?
    func beginTurn(session: AgentTabSession, initialMessage: String)
    func addUserInputTokens(_ tokens: Int, session: AgentTabSession)
    func addToolInputPayload(_ payload: String?, session: AgentTabSession)
    func addToolOutputPayload(_ payload: String?, session: AgentTabSession)

    @discardableResult
    func ingestUsageSignal(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot?

    @discardableResult
    func ingestTurnFinalizationSignal(
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot?

    func ingestStatusSignal(_ statusText: String?, session: AgentTabSession)
    func ingestSystemSignal(_ systemText: String?, session: AgentTabSession)

    @discardableResult
    func finalizeTurn(
        promptTokens: Int?,
        completionTokens: Int?,
        contextUsedTokens: Int?,
        session: AgentTabSession
    ) -> Bool

    @discardableResult
    func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot?
}

extension ContextUsageEstimating {
    @discardableResult
    func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session _: AgentTabSession
    ) -> ContextUsageSnapshot? {
        _ = usage
        return nil
    }
}
