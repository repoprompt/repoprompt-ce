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
        session.runID = runID
        return runID
    }

    static func clearProcessRunID(for session: AgentModeViewModel.TabSession) {
        session.runID = nil
    }
}
