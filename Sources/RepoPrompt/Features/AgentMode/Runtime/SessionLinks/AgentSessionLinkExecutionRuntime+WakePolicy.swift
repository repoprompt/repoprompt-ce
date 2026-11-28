import Foundation
import RepoPromptDomainRuntime

extension AgentSessionLinkExecutionRuntime {
    enum WakePolicyChange {
        case automaticUpdates(Bool)
        case selectedTargets(Set<UUID>)
        case routineInterval(enabled: Bool, seconds: Int)
        case periodicIdle(enabled: Bool, seconds: Int)
    }

    /// Policy writes and the matching admission fences belong to the session's writer.
    /// A presentation observes the committed values and can update its index afterward.
    @discardableResult
    func setWakePolicy(_ change: WakePolicyChange, for endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
        guard let command = admit(endpoint: endpoint), command.writer.session.hasLoadedPersistedState else { return false }
        let owner = command.writer.scope
        let session = command.writer.session
        let previous = session.oversight
        switch change {
        case let .automaticUpdates(enabled):
            guard previous.autoWakeOnUpdates != enabled else { return true }
            session.oversight.autoWakeOnUpdates = enabled
        case let .selectedTargets(targets):
            guard previous.autoWakeTargetSessionIDs != targets else { return true }
            session.oversight.autoWakeTargetSessionIDs = targets
        case let .routineInterval(enabled, seconds):
            let seconds = AgentSessionLinkRoutineWakeInterval.normalized(seconds)
            guard previous.routineWakeIntervalEnabled != enabled || previous.routineWakeIntervalSeconds != seconds else { return true }
            session.oversight.routineWakeIntervalEnabled = enabled
            session.oversight.routineWakeIntervalSeconds = seconds
        case let .periodicIdle(enabled, seconds):
            let seconds = AgentSessionLinkPeriodicWakeInterval.normalized(seconds)
            guard previous.periodicIdleWakeEnabled != enabled || previous.periodicIdleWakeIntervalSeconds != seconds else { return true }
            session.oversight.periodicIdleWakeEnabled = enabled
            session.oversight.periodicIdleWakeIntervalSeconds = seconds
        }
        session.isDirty = true
        owner.persistence.scheduleSave(for: session)
        switch change {
        case let .automaticUpdates(enabled):
            if enabled { agentSessionLinkClearAutoWakeSuppression(for: endpoint) }
            agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
        case .selectedTargets:
            agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
        case .routineInterval:
            agentSessionLinkNoteRoutineWakeIntervalChanged(for: endpoint)
        case .periodicIdle:
            agentSessionLinkReconcilePeriodicWake(for: endpoint)
        }
        session.monitorObservationSignal.send(())
        owner.presentation.oversightPolicyChanged(session)
        return true
    }
}
