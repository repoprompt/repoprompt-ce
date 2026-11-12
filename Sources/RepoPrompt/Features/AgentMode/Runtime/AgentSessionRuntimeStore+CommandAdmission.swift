import Foundation

extension AgentSessionRuntimeStore {
    enum AdmissionRejection: Error {
        case unavailable(Unavailable), conflicting, foreignOwner
        case command(Writer, CommandRejection)
    }
}

extension AgentSessionRuntimeStore.Scope {
    /// Resolution, exact ownership and command readiness remain distinct failures. Only command
    /// refusal carries a resolved writer, for surfaces that distinguish refused from superseded.
    func admit(
        session: AgentTabSession,
        expectedWorkspaceID: UUID? = nil,
        requirement: AgentSessionRuntimeStore.CommandRequirement = .restored
    ) throws(AgentSessionRuntimeStore.AdmissionRejection) -> AgentSessionRuntimeStore.Command {
        guard let id = session.activeAgentSessionID else { throw AgentSessionRuntimeStore.AdmissionRejection.unavailable(.absent) }
        switch resolveWriter(sessionID: id, expectedWorkspaceID: expectedWorkspaceID) {
        case let .unavailable(reason): throw AgentSessionRuntimeStore.AdmissionRejection.unavailable(reason)
        case .conflicting: throw AgentSessionRuntimeStore.AdmissionRejection.conflicting
        case let .unique(writer):
            guard writer.scope === self, writer.session === session else { throw AgentSessionRuntimeStore.AdmissionRejection.foreignOwner }
            return try writer.admitCommand(requirement).mapError { AgentSessionRuntimeStore.AdmissionRejection.command(writer, $0) }.get()
        }
    }
}

extension AgentSessionRuntimeStore.Command {
    var rejection: AgentSessionRuntimeStore.CommandRejection? {
        if case let .failure(reason) = writer.admitCommand(requirement) { return reason }
        return nil
    }

    /// Consent, operation and cancellation fences stay with callers, including their ordering.
    func requireCurrent() throws(AgentSessionRuntimeStore.CommandRejection) {
        if let rejection { throw rejection }
    }
}

extension AgentSessionRuntimeStore.Writer {
    /// Cleanup of an admitted effect may settle the detached original object. Reacquiring the
    /// same object's slot is not detachment. This is neither command nor persistent-claim admission.
    var isCurrentOrSlotReplaced: Bool {
        isCurrent || scope.sessions[session.tabID] !== session
    }
}
