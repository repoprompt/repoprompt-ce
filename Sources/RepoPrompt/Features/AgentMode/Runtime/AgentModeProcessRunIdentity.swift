import Foundation

@MainActor
enum AgentModeProcessRunIdentity {
    static func existingProcessRunID(for session: AgentModeViewModel.TabSession) -> UUID? {
        session.runID
    }

    static func mostRecentTranscriptProcessRunID(for session: AgentModeViewModel.TabSession) -> UUID? {
        session.transcript.turns.last?.responseSpans.reversed().compactMap(\.runID).first
    }

    @discardableResult
    static func retainProcessRunID(
        _ runID: UUID,
        inTranscriptTurnID turnID: UUID,
        for session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard let turnIndex = session.transcript.turns.firstIndex(where: { $0.id == turnID }),
              let spanIndex = session.transcript.turns[turnIndex].responseSpans.indices.last
        else {
            return false
        }
        let existingRunID = session.transcript.turns[turnIndex].responseSpans[spanIndex].runID
        guard existingRunID == nil || existingRunID == runID else {
            return false
        }
        if existingRunID == nil {
            session.transcript.turns[turnIndex].responseSpans[spanIndex].runID = runID
            session.isDirty = true
        }
        return true
    }

    static func startFreshProcessRun(for session: AgentModeViewModel.TabSession) -> UUID {
        let runID = UUID()
        session.installRunID(runID)
        return runID
    }

    /// Returns the live process run ID, installing a fresh one when none is
    /// present. Use on start/resume paths that reuse an in-flight identity.
    static func ensureProcessRunID(for session: AgentModeViewModel.TabSession) -> UUID {
        if let existing = session.runID {
            return existing
        }
        return startFreshProcessRun(for: session)
    }

    /// Host-authoritative force reset: unconditionally clears whatever run
    /// identity is present, including a successor's. Reserved for transitions
    /// whose contract is "no run may survive" (tab/window close, session
    /// delete, provider identity change, workspace switch, execution-location
    /// change, user cancel). The caller's authority decision and this call must
    /// not be separated by a suspension point unless a successor started during
    /// that suspension is also invalid in the new context. Run-scoped cleanup
    /// must use `TabSession.clearRunID(ifCurrent:)` instead.
    static func clearProcessRunID(for session: AgentModeViewModel.TabSession) {
        session.runLifecycle.forceClearRunID()
    }
}
