import Foundation
import RepoPromptDomainRuntime

/// Cross-window endpoint source for oversight links.
///
/// This is the only place that walks `allWindows` on oversight's behalf. It never switches, focuses,
/// or activates a window: resolution, snapshotting, and observation are strictly read-only with
/// respect to window state.
extension WindowStatesManager: AgentSessionLinkEndpointHost {
    func agentSessionLinkCandidates(includeLocation: Bool) -> [AgentSessionLinkEndpointCandidate] {
        guard !isTerminating else { return [] }
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        for window in allWindows where !window.isClosing {
            guard modelRoutingWindow(withID: window.windowID) === window else { continue }
            candidates.append(
                contentsOf: window.agentModeViewModel.agentSessionLinkCandidates(isWindowClosing: false, includeLocation: includeLocation)
            )
        }
        return candidates
    }

    func agentSessionLinkCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity, includeLocation: Bool
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let window = modelRoutingWindow(withID: endpoint.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkCandidate(for: endpoint, includeLocation: includeLocation)
    }

    func agentSessionLinkCandidates(
        forSessionIDs sessionIDs: Set<UUID>, includeLocation: Bool
    ) -> [UUID: [AgentSessionLinkEndpointCandidate]] {
        var result = Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, [AgentSessionLinkEndpointCandidate]()) })
        guard !isTerminating else { return result }
        for window in allWindows where !window.isClosing {
            guard modelRoutingWindow(withID: window.windowID) === window else { continue }
            let local = window.agentModeViewModel.agentSessionLinkCandidates(
                forSessionIDs: sessionIDs, includeLocation: includeLocation
            )
            for sessionID in sessionIDs {
                result[sessionID, default: []] += local[sessionID] ?? []
            }
        }
        return result
    }

    func agentSessionLinkObservationSnapshot(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot {
        guard let window = window(withID: candidate.windowID) else {
            return DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                board: DomainAgentSessionLaneBoard(
                    runOutcome: .none,
                    failureReason: nil,
                    sendBlockers: [AgentModeViewModel.SendBlocker.sessionUnavailable.rawValue],
                    subagentRunning: 0,
                    subagentFinished: 0
                ),
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date()
            )
        }
        return window.agentModeViewModel.agentSessionLinkObservationSnapshot(for: candidate)
    }

    func agentSessionLinkRefreshSubagentCensus(
        for candidates: [AgentSessionLinkEndpointCandidate]
    ) async {
        guard !isTerminating else { return }
        // One metadata load per workspace/window in a multi-target poll or wait. Never activate a
        // workspace or switch focus just to observe it.
        var refreshed: Set<String> = []
        for candidate in candidates {
            guard let window = window(withID: candidate.windowID),
                  !window.isClosing,
                  let workspace = window.workspaceManager.activeWorkspace,
                  workspace.id == candidate.workspaceID
            else { continue }
            let key = "\(candidate.windowID):\(workspace.id.uuidString)"
            guard refreshed.insert(key).inserted else { continue }
            await window.agentModeViewModel.agentSessionLinkRefreshSubagentCensus(for: workspace)
        }
    }

    func agentSessionLinkForgetDeletedSubagent(_ sessionID: UUID) {
        guard !isTerminating else { return }
        for window in allWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkForgetDeletedSubagent(sessionID)
        }
    }

    func agentSessionLinkStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkStatusProjection? {
        guard let window = window(withID: candidate.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkStatusProjection(for: candidate)
    }

    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        guard let window = window(withID: candidate.windowID) else { return false }
        return window.agentModeViewModel.agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate)
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        guard let window = window(withID: candidate.windowID) else { return [] }
        return window.agentModeViewModel.agentSessionLinkAutoWakeTargetSessionIDs(for: candidate)
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _ enabled: Bool,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(enabled, for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _ targetSessionIDs: Set<UUID>,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(targetSessionIDs, for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetRoutineWakeInterval(
        enabled: Bool,
        seconds: Int,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetRoutineWakeInterval(
            enabled: enabled,
            seconds: seconds,
            for: endpoint
        )
    }

    @discardableResult
    func agentSessionLinkSetPeriodicIdleWake(
        enabled: Bool,
        seconds: Int,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetPeriodicIdleWake(
            enabled: enabled,
            seconds: seconds,
            for: endpoint
        )
    }

    /// Routes one `Wake now` request to the view model that *is* this exact incarnation.
    ///
    /// Same addressing rule as the policy writes above: a superseded incarnation must not have a turn
    /// reserved on the live one that replaced it.
    @discardableResult
    func agentSessionLinkRequestManualWakeNow(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentMonitorWakeNowOutcome {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .refused(.observerUnavailable)
        }
        return viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetWaitingOn(
        _ waitingOn: DomainAgentSessionWaitingOn?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetWaitingOn(waitingOn, for: endpoint)
    }

    /// Routes one pure Auto-wake snooze read to the view model that *is* this exact incarnation.
    ///
    /// Addressed exactly like every other endpoint-scoped call here: a session UUID is not an address,
    /// and an in-place rebind keeps that UUID while advancing the binding generations. A retired or
    /// replaced endpoint therefore fails closed rather than reading a namesake's policy.
    func agentSessionLinkAutoWakeSnoozeProjection(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        return viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        )
    }

    /// Routes one Auto-wake snooze mutation to the view model that *is* this exact incarnation.
    ///
    /// The same-session-UUID replacement case is the one this exists to refuse: a stale monitor row or
    /// a late MCP call naming a superseded incarnation must not install or clear policy on the live
    /// one.
    func agentSessionLinkMutateAutoWakeSnooze(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        return viewModel.agentSessionLinkMutateAutoWakeSnooze(
            endpoint: endpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference,
            command: command,
            origin: origin
        )
    }

    func agentSessionLinkInstallObservation(
        for candidate: AgentSessionLinkEndpointCandidate,
        onChange: @escaping @MainActor () -> Void
    ) -> AgentSessionLinkObservationToken? {
        guard let window = window(withID: candidate.windowID), !window.isClosing else { return nil }
        return window.agentModeViewModel.agentSessionLinkInstallObservation(
            for: candidate,
            onChange: onChange
        )
    }

    /// Routes an Oversee projection to the one window/tab that *is* this endpoint incarnation.
    ///
    /// Previously this fanned out to every non-closing window holding a session with the same UUID.
    /// Duplicate live incarnations are explicitly modelled (the resolver refuses them as
    /// `.ambiguous`), so that fan-out handed an unauthorized incarnation the granted incarnation's
    /// rows, notices, and — through the prompt inventory — its agent-facing oversight supplement.
    func agentSessionLinkPublishProjection(
        _ props: AgentMonitorPillProps,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishProjection(props, to: endpoint)
    }

    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishPromptInventory(inventory, to: endpoint)
    }

    func agentSessionLinkPublishRunCatalogProjection(
        _ projection: AgentSessionLinkRunCatalogProjection
    ) {
        guard let endpoint = projection.routeToken?.observerEndpoint,
              let viewModel = agentSessionLinkOwningViewModel(for: endpoint)
        else { return }
        viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
    }

    /// Routes one passive status-notice queue to the exact incarnation it was reduced for.
    ///
    /// Addressed like every other publication here: a session UUID is not an address, and a queue
    /// handed to a namesake incarnation would let it claim notices about targets it never observed.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64? {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return nil }
        return viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
    }

    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkReleasePromptInventoryHold(
            token,
            for: endpoint,
            publishing: inventory
        )
    }

    /// The view model that currently owns this exact endpoint incarnation, or `nil`.
    private func agentSessionLinkOwningViewModel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentModeViewModel? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else {
            return nil
        }
        let viewModel = window.agentModeViewModel
        // Full incarnation match, not `(tabID, sessionID)`: an in-place rebind keeps both while
        // advancing the binding generations.
        guard viewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint else {
            return nil
        }
        return viewModel
    }

    func agentSessionLinkTranscriptPage(
        for candidate: AgentSessionLinkEndpointCandidate,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID?
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .failure(.endpointInvalidated)
        }
        return await window.agentModeViewModel.agentSessionLinkTranscriptPage(
            for: candidate,
            anchor: anchor,
            direction: direction,
            maxItems: maxItems,
            maxOutputBytes: maxOutputBytes,
            readerSessionID: readerSessionID
        )
    }

    /// Cross-window liveness for one send, answered in a single synchronous MainActor pass.
    ///
    /// The transaction itself runs on the target window's `AgentModeViewModel`, which cannot see the
    /// observer's window or its own window's teardown flag. Both facts are read here, from the same
    /// candidate snapshot, so the two fences the transaction crosses compare like with like. Nothing
    /// here focuses, activates, or switches a window.
    func agentSessionLinkSendLiveness(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkSendLiveness {
        guard !isTerminating else { return .unavailable }
        // Resolved independently of the candidate sweep: a window with no eligible candidates is not
        // the same thing as a window that is tearing down.
        let targetWindow = window(withID: target.windowID)
        let targetWindowIsClosing = targetWindow.map(\.isClosing) ?? true
        let live = agentSessionLinkCandidates()
        return AgentSessionLinkSendLiveness(
            observerEndpointIsLive: live.contains { $0.domainEndpoint == observer },
            targetEndpointIsLive: live.contains { $0.domainEndpoint == target },
            targetWindowIsClosing: targetWindowIsClosing
        )
    }

    /// Routes the send transaction to the exact owning window.
    ///
    /// Window liveness is re-checked here rather than trusted from the candidate: the whole
    /// transaction runs on that window's `AgentModeViewModel`, and a terminating manager or closing
    /// window must refuse before any target state is touched. Nothing here focuses or activates the
    /// window.
    func agentSessionLinkStartStopFence(for candidate: AgentSessionLinkEndpointCandidate) -> AgentRunStartStopFence? {
        guard !isTerminating,
              let window = window(withID: candidate.windowID), !window.isClosing,
              let session = window.agentModeViewModel.agentSessionLinkLiveSession(matching: candidate)
        else { return nil }
        return AgentRunStartStopFence(session: session)
    }

    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSend(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    // MARK: - Management delegation

    func agentSessionLinkModelAvailability(windowID: Int) -> AgentModelCatalog.AvailabilityContext {
        guard let window = modelRoutingWindow(withID: windowID) else { return .none }
        return window.apiSettingsViewModel.agentAvailability
    }

    func agentSessionLinkModelCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let window = modelRoutingWindow(withID: endpoint.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkModelCandidate(for: endpoint)
    }

    func agentSessionLinkPerformSetModel(
        to candidate: AgentSessionLinkEndpointCandidate,
        modelID: String,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        reauthorize: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = modelRoutingWindow(withID: candidate.windowID) else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSetModel(
            to: candidate, modelID: modelID, liveness: liveness,
            availability: { window.apiSettingsViewModel.agentAvailability }, reauthorize: reauthorize
        )
    }

    /// Routes one managed steer to the exact owning window, refusing during teardown before any
    /// target state is touched. Nothing here focuses or activates the window.
    func agentSessionLinkPerformSteer(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSteer(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    /// Routes Stop without focusing or activating the target window.
    func agentSessionLinkPerformStop(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkStopRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        queueHasCommittedDrain: @escaping @MainActor () -> Bool,
        withdrawInbound: @escaping @MainActor () -> Bool,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkStopTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformStop(
            to: candidate,
            request: request,
            liveness: liveness,
            queueHasCommittedDrain: queueHasCommittedDrain,
            withdrawInbound: withdrawInbound,
            commitAuthorization: commitAuthorization
        )
    }

    /// Routes a read-only interaction inspection to the exact owning window. Never focuses it.
    func agentSessionLinkPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkPendingInteractionInspection {
        guard !isTerminating,
              let window = window(withID: candidate.windowID),
              !window.isClosing
        else { return .none }
        return window.agentModeViewModel.agentSessionLinkPendingInteraction(for: candidate)
    }

    /// Routes one observer answer to the exact owning window, refusing during teardown.
    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard !isTerminating,
              let window = window(withID: candidate.windowID),
              !window.isClosing
        else { return .unavailable }
        return await window.agentModeViewModel.agentSessionLinkRespondToPendingInteraction(
            for: candidate,
            request: request,
            authorize: authorize
        )
    }

    /// Routes the compaction transaction to the exact owning window, with the same terminating and
    /// closing refusals as a send. Nothing here focuses or activates the window.
    func agentSessionLinkPerformCompact(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkCompactRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformCompact(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    // MARK: - Launch restoration inputs

    /// Identity-only descriptors for every compose-tab binding in every window's active workspace.
    ///
    /// Built from the workspace model rather than from live `TabSession`s, so a background tab that
    /// has never been visited is still *described*. That distinction is the whole reason automatic
    /// restoration can wait for natural hydration instead of force-loading every saved transcript.
    func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
        guard !isTerminating else { return [] }
        var descriptors: [AgentSessionLinkComposeTabDescriptor] = []
        for window in allWindows where !window.isClosing {
            descriptors.append(contentsOf: window.agentModeViewModel.agentSessionLinkComposeTabDescriptors())
        }
        return descriptors
    }

    /// Current discovery level of every registered, non-closing window.
    ///
    /// An empty result is meaningful: it means no window has described its bindings yet, and the
    /// coordinator must wait rather than conclude a saved session is absent.
    func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState] {
        guard !isTerminating else { return [] }
        return allWindows
            .filter { !$0.isClosing }
            .map(\.agentModeViewModel.agentSessionLinkDiscoveryState)
    }

    func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState {
        agentSessionOversightRestoreTopologyState
    }

    /// Fans a restoration hydration request out to every non-closing window. Each window loads only
    /// the compose tabs of its own active workspace that are bound to one of these sessions, in the
    /// background; nothing is selected, focused, or activated.
    func agentSessionLinkRequestRestorationHydration(sessionIDs: Set<UUID>) {
        guard !isTerminating, !sessionIDs.isEmpty else { return }
        for window in allWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkRequestRestorationHydration(sessionIDs: sessionIDs)
        }
    }

    /// Repaints every non-closing window with the process-wide durable-oversight level.
    ///
    /// Broadcast rather than addressed to an endpoint: a tab with no links at all never receives an
    /// authority projection, and that is precisely the tab whose Add button has to explain why saving
    /// is currently unavailable.
    func agentSessionLinkPublishPersistencePresentation(
        _ presentation: AgentSessionOversightPersistencePresentation
    ) {
        guard !isTerminating else { return }
        for window in allWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkApplyPersistencePresentation(presentation)
        }
    }

    // MARK: - Attachment and lifecycle invalidation

    /// Attaches the process-wide bridge to this manager. Idempotent; safe to call on every window
    /// registration.
    func attachAgentSessionLinkBridge() {
        AgentSessionLinkRuntimeBridge.shared.attach(host: self)
    }

    /// Republishes the outer restore topology to the launch coordinator.
    ///
    /// Called from the restore-gate transitions and from window registration/unregistration. The
    /// event carries nothing: the coordinator rereads the current level snapshot every pass.
    func notifyAgentSessionLinkTopologyChanged() {
        guard !isTerminating else { return }
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
    }

    /// Window close/unregister. Revokes every link with either endpoint in that window.
    ///
    /// Fired before the surviving endpoints repaint so both sides observe one authority transition.
    func invalidateAgentSessionLinks(forClosedWindowID windowID: Int) {
        guard !isTerminating else { return }
        Task { @MainActor in
            await AgentSessionLinkRuntimeBridge.shared.invalidateWindow(windowID, reason: .windowClosed)
        }
    }

    /// Workspace switch on one window. Only links bound to the window's previous workspace are
    /// revoked; links held by other windows on that workspace survive.
    func invalidateAgentSessionLinks(forWindowID windowID: Int, leavingWorkspaceID workspaceID: UUID) {
        guard !isTerminating else { return }
        Task { @MainActor in
            await AgentSessionLinkRuntimeBridge.shared.invalidateWorkspace(
                workspaceID,
                windowID: windowID,
                reason: .workspaceSwitched
            )
        }
    }
}
