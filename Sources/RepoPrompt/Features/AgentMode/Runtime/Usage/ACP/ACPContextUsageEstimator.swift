import Foundation

/// Telemetry-only context-usage capture for ACP-backed providers (Devin, Cursor, OpenCode,
/// Grok Build, Antigravity). Records the provider's own reported figures so the context ring and
/// the session-link oversight `context` field have data, but performs no token accounting: no
/// queued user-turn estimates, no per-turn persisted usage rows, and no rebuilt-from-history
/// fallbacks.
///
/// Signals:
/// - `usage_update` (`ingestUsageSignal`): `used` is the provider's reported context occupancy
///   and `size` its context window, so the snapshot is `exact`. An occupancy report also marks
///   the turn: a later billed prompt-call count from the same turn may not replace it, since the
///   billed figure can be cumulative across the turn's internal requests.
/// - Prompt-response usage (`ingestTurnFinalizationSignal`): `inputTokens` plus the cache fields
///   are billed per-call input, so the snapshot is `bestEffort` — unless the provider already
///   reported occupancy this turn, in which case only a new window is adopted. A billed count
///   that exceeds the known window is provably cumulative rather than occupancy and is not
///   stored as the context count.
///
/// A call carrying no fresh figure never touches the snapshot, so it cannot downgrade a better
/// label. ACP carries no verified compaction signal, so the status/system hooks are no-ops; a
/// post-compaction usage report self-corrects the figure. Providers that emit neither signal
/// keep a nil snapshot and report unknown.
@MainActor
final class ACPContextUsageEstimator: ContextUsageEstimating {
    /// Representative kind only — one shared instance serves every ACP provider because all
    /// per-session state lives on the session.
    let agent: AgentProviderKind = .devin

    /// The epoch a live occupancy report belongs to — the same fields that reset the session's
    /// vouches, so a marker cannot extend a report into an epoch it was not made in.
    private struct OccupancyEpoch: Equatable {
        let agent: AgentProviderKind
        let modelRaw: String
    }

    private func occupancyEpoch(for session: AgentTabSession) -> OccupancyEpoch {
        OccupancyEpoch(agent: session.selectedAgent, modelRaw: session.selectedModelRaw)
    }

    /// Sessions whose current turn included a `usage_update` occupancy report, stamped with the
    /// epoch it was reported under. Consumed at turn finalization and cleared at `beginTurn`;
    /// a stale entry only makes the estimator conservative about billed counts. Steering
    /// prompts inside one run each consume it, so a steering turn's own billed count is
    /// evaluated on its own.
    private var sessionsWithOccupancyReportThisTurn: [ObjectIdentifier: OccupancyEpoch] = [:]

    func hasOccupancyReportThisTurn(session: AgentTabSession) -> Bool {
        sessionsWithOccupancyReportThisTurn[ObjectIdentifier(session)] == occupancyEpoch(for: session)
            && session.contextUsageSnapshot?.used != nil
    }

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

    func beginTurn(session: AgentTabSession, initialMessage _: String) {
        sessionsWithOccupancyReportThisTurn.removeValue(forKey: ObjectIdentifier(session))
    }

    func addUserInputTokens(_: Int, session _: AgentTabSession) {}

    func addToolInputPayload(_: String?, session _: AgentTabSession) {}

    func addToolOutputPayload(_: String?, session _: AgentTabSession) {}

    func ingestStatusSignal(_: String?, session _: AgentTabSession) {}

    func ingestSystemSignal(_: String?, session _: AgentTabSession) {}

    @discardableResult
    func ingestUsageSignal(
        promptTokens _: Int?,
        completionTokens _: Int?,
        contextUsedTokens: Int?,
        modelContextWindow: Int?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot? {
        let existing = session.codexContextUsage
        let freshWindow = normalizedPositive(modelContextWindow)
        let resolvedWindow = freshWindow ?? existing?.modelContextWindow
        let reportedUsed = normalizedContextUsedTokens(
            contextUsedTokens,
            modelContextWindow: resolvedWindow
        )
        // The marker mirrors the turn's latest occupancy claim: a positive `used` records it,
        // while an explicit count claim that yields no usable figure (`used: 0`, or a count that
        // cannot fit the window) releases the hold. Window-only and context-free updates carry
        // no occupancy claim and leave the marker alone.
        if reportedUsed != nil {
            sessionsWithOccupancyReportThisTurn[ObjectIdentifier(session)] = occupancyEpoch(for: session)
        } else if contextUsedTokens != nil {
            sessionsWithOccupancyReportThisTurn.removeValue(forKey: ObjectIdentifier(session))
        }
        // A call carrying no fresh figure must not relabel the snapshot it would carry forward.
        guard reportedUsed != nil || freshWindow != nil else { return nil }
        // A carried-forward figure that no longer fits a freshly reported window is not current
        // — for the count or the total the ring falls back to when the count is absent.
        var resolvedUsed = reportedUsed ?? existing?.lastTotalTokens
        var resolvedTotal = resolvedUsed ?? existing?.totalTotalTokens
        if let freshWindow {
            if let used = resolvedUsed, used > freshWindow {
                resolvedUsed = nil
            }
            if let total = resolvedTotal, total > freshWindow {
                resolvedTotal = nil
            }
        }
        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedTotal
        )
        return updateSnapshot(
            from: session.codexContextUsage,
            // A carried-forward figure keeps its origin: a window-only or non-confirming update
            // must not relabel a billed count as an occupancy report. A count with no recorded
            // provenance defaults to the billed label so the discredited-series drop still applies.
            source: reportedUsed != nil
                ? .acpUsageEvent
                : (session.contextUsageSnapshot?.source ?? .turnFinalization),
            confidence: reportedUsed != nil ? .exact : .bestEffort,
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
        let freshWindow = normalizedPositive(modelContextWindow)
        let resolvedWindow = freshWindow ?? existing?.modelContextWindow
        let reportedUsed = normalizedContextUsedTokens(
            contextUsedTokens,
            modelContextWindow: resolvedWindow
        )
        // The per-turn occupancy marker belongs to the turn this finalization ends; consume it
        // up front so even an early return resets it for the next prompt.
        let sawOccupancyThisTurn = sessionsWithOccupancyReportThisTurn.removeValue(
            forKey: ObjectIdentifier(session)
        )
        // A call carrying no fresh figure must not relabel the snapshot it would carry forward;
        // a positive report still counts as fresh even when the window bound rejects it.
        let rejectedOverWindow = normalizedPositive(contextUsedTokens) != nil && reportedUsed == nil
        guard reportedUsed != nil || freshWindow != nil || rejectedOverWindow else { return nil }
        // A billed prompt-call count can be cumulative across the turn's internal requests, so it
        // never replaces a same-turn occupancy figure or a stored figure from an earlier turn.
        // The marker requires a current figure to hold: the snapshot is reset on provider or
        // model change and on clear, while the usage store is not.
        let holdsOccupancy = sawOccupancyThisTurn == occupancyEpoch(for: session)
            && session.contextUsageSnapshot?.used != nil
        // A rejected billed count also discredits a stored count from the same billed series.
        let carriedUsed = rejectedOverWindow && session.contextUsageSnapshot?.source == .turnFinalization
            ? nil
            : existing?.lastTotalTokens
        var resolvedUsed = holdsOccupancy
            ? existing?.lastTotalTokens
            : (reportedUsed ?? carriedUsed)
        var resolvedTotal = existing?.totalTotalTokens
        // A freshly reported window bounds held and carried figures alike — including the total
        // the ring falls back to when the count is absent.
        if let freshWindow {
            if let used = resolvedUsed, used > freshWindow {
                resolvedUsed = nil
            }
            if let total = resolvedTotal, total > freshWindow {
                resolvedTotal = nil
            }
        }
        // A total that merely mirrored a dropped count drops with it; a different figure stays.
        if resolvedUsed == nil, existing?.totalTotalTokens == existing?.lastTotalTokens {
            resolvedTotal = nil
        }
        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: resolvedWindow,
            lastTotalTokens: resolvedUsed,
            totalTotalTokens: resolvedUsed ?? resolvedTotal
        )
        // The billed labels apply only when a billed count was actually adopted as the context
        // figure; a declined report or a window-only call keeps whatever label the figure has.
        let adoptedBilled = !holdsOccupancy && reportedUsed != nil
        return updateSnapshot(
            from: session.codexContextUsage,
            source: adoptedBilled
                ? .turnFinalization
                : (session.contextUsageSnapshot?.source ?? .turnFinalization),
            confidence: adoptedBilled
                ? .bestEffort
                : (session.contextUsageSnapshot?.confidence ?? .bestEffort),
            session: session
        )
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

    private func normalizedPositive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// `nil` when the count is absent, non-positive, or larger than the window the provider
    /// reported — a count that cannot fit is billed or cumulative, not occupancy.
    private func normalizedContextUsedTokens(
        _ contextUsedTokens: Int?,
        modelContextWindow: Int?
    ) -> Int? {
        let normalized = max(0, contextUsedTokens ?? 0)
        guard normalized > 0 else { return nil }
        if let window = normalizedPositive(modelContextWindow), normalized > window {
            return nil
        }
        return normalized
    }

    private func updateSnapshot(
        from usage: AgentContextUsage?,
        source: ContextUsageSnapshotSource,
        confidence: ContextUsageSnapshotConfidence,
        session: AgentTabSession
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
}
