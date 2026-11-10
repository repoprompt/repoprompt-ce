import Foundation

extension AgentSessionRuntimeStore.Scope {
    /// Legacy retirement must not turn close-cancels-run into background notifications. The
    /// independent host's later presentation-only detach will deliberately keep its sink installed.
    func removeDetachedNotificationSink() {
        presentation.detachedSink = nil
        detachedNotificationCleanup?()
        detachedNotificationCleanup = nil
    }

    /// Host composition installs once. Only exact, unpresented objects publish app notifications;
    /// the ordinary VM sink retains all existing notification policy while attached. A host may
    /// supply a canonical name reader; the fallback never reaches into optional VM state.
    func installDetachedNotificationSink(
        routeID: Int,
        coordinator suppliedCoordinator: AgentNotificationCoordinator? = nil,
        displayName: @escaping (AgentTabSession) -> String = { _ in "Agent" }
    ) {
        guard detachedNotificationCleanup == nil else { return }
        let coordinator = suppliedCoordinator ?? NotificationService.shared.agentNotifications
        let projectionID = UUID()
        let state: (AgentTabSession, Bool) -> AgentAttentionState? = { [weak self] session, interaction in
            guard let self, sessions[session.tabID] === session,
                  !presentation.hasPresenter(for: session),
                  let binding = session.persistentSessionBindingIdentity, let workspaceID = binding.workspaceID
            else { return nil }
            return AgentAttentionState(
                windowID: routeID, workspaceID: workspaceID, tabID: session.tabID,
                sessionID: binding.sessionID, sessionName: displayName(session),
                isMCPControlled: session.mcpControlContext != nil,
                interaction: interaction ? AgentPendingInteractionDescriptor.make(from: session) : nil,
                turnMarker: interaction ? nil : AgentNotificationTurnMarker.make(from: session)
            )
        }
        presentation.detachedSink = .init(
            turnComplete: { session in
                guard let snapshot = state(session, false) else { return }
                coordinator.postTurnOutcome(.completed(preview: AgentTranscriptIO.latestAssistantPreviewText(from: session.transcript)), for: snapshot)
            },
            turnFailed: { session, error in
                guard let snapshot = state(session, false) else { return }
                coordinator.postTurnOutcome(.failed(message: error), for: snapshot)
            },
            stateChanged: { [weak self] in
                let states = self?.sessions.values.sorted { $0.tabID.uuidString < $1.tabID.uuidString }
                    .compactMap { state($0, true) } ?? []
                coordinator.updateDetachedScope(projectionID, states: states)
            }
        )
        detachedNotificationCleanup = {
            Task { @MainActor in coordinator.updateDetachedScope(projectionID, states: []) }
        }
        presentation.refreshDetachedState()
    }
}
