import Combine
import Foundation
import RepoPromptDomainRuntime

// The window-local host surface for oversight: candidates, exact projections, and observation.
//
// This extension is where the view model exposes its live sessions to the oversight subsystem —
// endpoint candidates for `AgentSessionLinkEndpointResolver`, the exact per-endpoint monitor
// projection and its single post-storage invalidation seam
// (`agentSessionLinkMutateProjectionStorage`), durable Auto-wake selection writes, `waiting_on`
// publication, and the status observation the runtime bridge subscribes to. It coordinates with
// `AgentSessionLinkRuntimeBridge` (process-wide owner of links and observations) and
// `AgentModeViewModel+SessionLinkAutoWake` (which it fences on every selection change).
// Invariants: the projection map is mutated in exactly one place and posts exactly one notification
// per logical batch, and a presentation-only repaint can never publish prompt inventory, reconcile
// the passive queue, or become an Auto-wake.

// MARK: - Narrow lifecycle-identity adapter

extension AgentSessionLifecycleAuthority.Identity {
    /// Maps the app-owned lifecycle identity onto the domain endpoint DTO.
    ///
    /// This is deliberately the only conversion in the codebase: the domain actor must never learn
    /// about `AgentSessionLifecycleAuthority`, and oversight must never invent an endpoint from a
    /// raw `(tabID, sessionID)` pair. A `nil` `sessionID` yields `nil` rather than an endpoint that
    /// could compare equal to another unbound tab.
    func monitorEndpoint(windowID: Int) -> DomainAgentSessionLinkEndpointIdentity? {
        guard let sessionID else { return nil }
        return DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration
        )
    }
}

// MARK: - Location projection

/// One live incarnation and the execution-location label its observers currently render.
///
/// UI only, exactly like the label on the candidate it mirrors: it never enters an agent-facing
/// snapshot, inventory, prompt, or MCP payload.
struct AgentSessionLinkLocationProjection: Equatable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let label: String
}

// MARK: - Candidates, snapshots, and observation

extension AgentModeViewModel {
    /// Live oversight candidates owned by this window, taken without focusing, activating, or
    /// switching anything.
    ///
    /// - Parameter isWindowClosing: the owning window's `isClosing` flag. A closing window's tabs are
    ///   never offered as endpoints.
    func agentSessionLinkCandidates(isWindowClosing: Bool) -> [AgentSessionLinkEndpointCandidate] {
        guard let workspaceManager else { return [] }
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        for workspace in workspaceManager.workspaces {
            // Only the active workspace of this window has live tab bindings; a background
            // workspace's tabs are persisted projections, not live endpoints.
            guard workspace.id == workspaceManager.activeWorkspaceID else { continue }
            for tab in workspace.composeTabs {
                guard let sessionID = tab.activeAgentSessionID,
                      let candidate = agentSessionLinkCandidate(
                          tabID: tab.id,
                          sessionID: sessionID,
                          tabName: tab.name,
                          isWindowClosing: isWindowClosing
                      )
                else { continue }
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // MARK: - Discovery epochs and lazy binding descriptors

    /// Starts a new discovery level for one workspace activation.
    ///
    /// Called at the start of every activation this window still owns. A superseded activation that
    /// began a level and then exited early simply leaves that level behind: its successor began a
    /// newer one, and only the newest level is ever read.
    @discardableResult
    func beginAgentSessionLinkDiscoveryEpoch(workspaceID: UUID?) -> AgentSessionLinkDiscoveryEpoch {
        agentSessionLinkDiscoveryGeneration &+= 1
        agentSessionLinkDiscoveryWorkspaceID = workspaceID
        return AgentSessionLinkDiscoveryEpoch(
            windowID: windowID,
            workspaceID: workspaceID,
            generation: agentSessionLinkDiscoveryGeneration
        )
    }

    /// Marks one level complete, and only if it is still the current one.
    ///
    /// This is the stale-owner fence: an activation that was superseded while suspended resumes,
    /// reaches its exit, and finds its captured level is no longer current, so its completion is
    /// dropped instead of declaring a successor's bindings settled.
    func completeAgentSessionLinkDiscoveryEpoch(_ epoch: AgentSessionLinkDiscoveryEpoch) {
        guard epoch.windowID == windowID,
              epoch.generation == agentSessionLinkDiscoveryGeneration,
              epoch.workspaceID == agentSessionLinkDiscoveryWorkspaceID
        else {
            #if DEBUG
                // A stale workspace owner completing a level it no longer owns is the exact race the
                // fence exists for, so it is worth one line even though nothing changed.
                WorkspaceRestorePerfLog.event(
                    "oversight.discovery",
                    fields: [
                        "state": "stale_owner_ignored",
                        "windowID": String(epoch.windowID),
                        "epoch": String(epoch.generation),
                        "current": String(agentSessionLinkDiscoveryGeneration)
                    ]
                )
            #endif
            return
        }
        agentSessionLinkDiscoveryCompletedGeneration = epoch.generation
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.discovery",
                fields: [
                    "state": "current_owner_complete",
                    "windowID": String(epoch.windowID),
                    "epoch": String(epoch.generation)
                ]
            )
        #endif
        // Settling the current level is one of the barriers automatic restoration waits on, so it has
        // to wake reconciliation. The event carries nothing; the coordinator rereads every level.
        AgentSessionLinkCandidateReadinessSignal.didChange()
    }

    var agentSessionLinkDiscoveryState: AgentSessionLinkDiscoveryState {
        AgentSessionLinkDiscoveryState(
            epoch: AgentSessionLinkDiscoveryEpoch(
                windowID: windowID,
                workspaceID: agentSessionLinkDiscoveryWorkspaceID,
                generation: agentSessionLinkDiscoveryGeneration
            ),
            isComplete: agentSessionLinkDiscoveryCompletedGeneration == agentSessionLinkDiscoveryGeneration
        )
    }

    /// Identity-only descriptors for every compose-tab binding in this window's active workspace.
    ///
    /// Deliberately built from the workspace model rather than from `sessions`: a background tab that
    /// has never been visited has no live `TabSession` and would be invisible to the candidate sweep,
    /// which is exactly the case restoration must be able to *wait* on instead of concluding the
    /// session is gone. Reading the model hydrates nothing.
    func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
        guard let workspaceManager,
              let activeWorkspaceID = workspaceManager.activeWorkspaceID,
              let workspace = workspaceManager.workspaces.first(where: { $0.id == activeWorkspaceID })
        else {
            return []
        }
        return workspace.composeTabs.compactMap { tab in
            guard let sessionID = tab.activeAgentSessionID else { return nil }
            return AgentSessionLinkComposeTabDescriptor(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: tab.id,
                sessionID: sessionID
            )
        }
    }

    /// The exact live endpoint incarnation bound to one compose tab of this window.
    ///
    /// This is the single conversion used to turn server-owned connection routing
    /// (`connection → run policy → window/tab`) into an oversight endpoint, and to address a projection
    /// publication at one incarnation. It is deliberately read-only and creates nothing: an unbound
    /// or unresolvable tab yields `nil` so the caller fails closed instead of inventing an endpoint.
    func agentSessionLinkObserverEndpoint(tabID: UUID) -> DomainAgentSessionLinkEndpointIdentity? {
        guard let session = sessions[tabID],
              let sessionID = session.activeAgentSessionID,
              let identity = agentSessionLifecycleIdentity(tabID: tabID, expectedSessionID: sessionID)
        else {
            return nil
        }
        return identity.monitorEndpoint(windowID: windowID)
    }

    func agentSessionLinkCandidate(
        tabID: UUID,
        sessionID: UUID,
        tabName: String,
        isWindowClosing: Bool
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let session = sessions[tabID],
              let identity = agentSessionLifecycleIdentity(tabID: tabID, expectedSessionID: sessionID),
              identity.sessionID == sessionID
        else {
            return nil
        }
        return AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: identity.workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: identity.persistentBindingGeneration,
            bindingTransitionGeneration: identity.bindingTransitionGeneration,
            isTopLevel: session.parentSessionID == nil,
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            // Only a *committed* deletion is closing. The view-model teardown that finally removes
            // this candidate runs several awaits after the file is gone, so the tombstone has to keep
            // standing in for it — but an attempt that is merely running travels as
            // `isDeletionInProgress` instead, because it can still fail and `isClosing` is permanent.
            isClosing: isWindowClosing
                || AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID),
            isMCPControlled: session.mcpControlContext != nil,
            isMCPOriginated: session.isMCPOriginated,
            roleAllowsOutboundMonitoring: AgentSessionLinkToolPolicy.allowsOutboundMonitoring(
                taskLabelKind: session.mcpControlContext?.taskLabelKind
            ),
            displayName: tabName,
            providerDisplayName: session.selectedAgent.displayName,
            // Resolved here, in the endpoint's own window, because only this window knows both its
            // worktree bindings and its workspace. UI only; never enters an agent-facing payload.
            locationLabel: AgentMonitorLocationLabelFormatter.label(
                worktreeLabel: primaryExecutionWorktreeIndicator(forTabID: tabID)?.label,
                workspaceName: workspaceManager?.workspace(withID: identity.workspaceID)?.name
            ),
            // Qualified here, in the endpoint's own window, against the binding state read in this
            // same MainActor pass. A proof left over from a superseded binding degrades to pending
            // rather than travelling on the candidate as authoritative.
            restorationReadiness: session.qualifiedRestorationReadiness,
            isDeletionInProgress: AgentSessionDeletionRegistry.shared
                .isDeletionInProgress(sessionID: sessionID)
        )
    }

    /// One live incarnation's effective, UI-only execution-location label.
    ///
    /// Built from exactly the inputs the candidate carries, so a comparison across a mutation
    /// answers "would any Oversee row render differently?" rather than "did some worktree field
    /// change?". A color, icon, or head-only edit therefore compares equal and repaints nothing.
    func agentSessionLinkLocationProjection(forTabID tabID: UUID) -> AgentSessionLinkLocationProjection? {
        guard let endpoint = agentSessionLinkObserverEndpoint(tabID: tabID) else { return nil }
        return AgentSessionLinkLocationProjection(
            endpoint: endpoint,
            label: AgentMonitorLocationLabelFormatter.label(
                worktreeLabel: primaryExecutionWorktreeIndicator(forTabID: tabID)?.label,
                workspaceName: workspaceManager?.workspace(withID: endpoint.workspaceID)?.name
            )
        )
    }

    /// Repaints the observers of one tab when its effective location label actually changed.
    ///
    /// Presentation only: it fires the projection-only sink and nothing else. A changed *endpoint*
    /// is deliberately not treated as a location delta — an in-place rebind is a lifecycle event the
    /// authoritative paths already own, and repainting a superseded incarnation's observers here
    /// would only race them.
    func notifyAgentSessionLinkLocationChange(
        forTabID tabID: UUID,
        from previous: AgentSessionLinkLocationProjection?
    ) {
        guard let previous,
              let current = agentSessionLinkLocationProjection(forTabID: tabID),
              current.endpoint == previous.endpoint,
              current.label != previous.label
        else {
            return
        }
        AgentSessionLinkLocationInvalidationSink.locationChanged(
            forExactTargetEndpoints: [current.endpoint]
        )
    }

    /// Sanitized status projection for one live endpoint.
    ///
    /// This carries status only. Interaction identifiers, prompt/option bodies, tool payloads, run
    /// identifiers, paths, and worktree metadata never enter it; the domain snapshot additionally
    /// normalizes and byte-caps every textual field it accepts.
    func agentSessionLinkObservationSnapshot(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot {
        guard let session = sessions[candidate.tabID] else {
            return DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date()
            )
        }
        return Self.observationSnapshot(for: session, candidate: candidate)
    }

    /// Status/activity-only projection: run state, pending interaction, and canonical activity.
    ///
    /// This is the UI path. It deliberately does not touch `items`, the canonical row count, or the
    /// assistant preview, so rendering an Oversee row never scans a transcript or runs the redaction
    /// regexes.
    /// The exact observer session's persisted **Auto-wake on updates** setting.
    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        guard let session = sessions[candidate.tabID],
              session.activeAgentSessionID == candidate.sessionID
        else {
            return false
        }
        return session.oversight.autoWakeOnUpdates
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        guard let session = sessions[candidate.tabID],
              session.activeAgentSessionID == candidate.sessionID
        else { return [] }
        return session.oversight.autoWakeTargetSessionIDs
    }

    /// Writes that setting to one exact observer incarnation.
    ///
    /// Endpoint-checked before the write, marked dirty so the existing scheduled persistence saves
    /// it, and mirrored into the owner-validated index immediately so a sidebar rebuild or a cold
    /// reseed cannot resurrect the previous value.
    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _ enabled: Bool,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID],
              session.hasLoadedPersistedState
        else {
            return false
        }
        guard session.oversight.autoWakeOnUpdates != enabled else { return true }
        session.oversight.autoWakeOnUpdates = enabled
        session.isDirty = true
        scheduleSave(for: endpoint.tabID)
        if var entry = ownerValidatedSessionIndex[endpoint.sessionID] {
            entry.autoWakeOnOversightUpdates = enabled
            sessionIndexStore.applyLocalUpsert(entry)
        }
        // Re-enabling is an explicit recovery action and clears only failure suppression; it invents
        // no admission basis, so a lane with no genuinely new content stays silent. Disabling never
        // clears the queue and does not preemptively cancel: the shared selection fence below retracts
        // routine status/overflow attempts while retaining exact purposeful attention, which is not
        // governed by routine Auto-wake selection.
        if enabled {
            agentSessionLinkClearAutoWakeSuppression(for: endpoint)
        }
        // Turning the master off may leave granular lanes effective, and turning it on selects every
        // lane at once. Either way the resulting per-target selection is fenced synchronously here
        // rather than waiting for the projection this signal schedules.
        agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
        session.monitorObservationSignal.send(())
        return true
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _ targetSessionIDs: Set<UUID>,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID],
              session.hasLoadedPersistedState
        else { return false }
        guard session.oversight.autoWakeTargetSessionIDs != targetSessionIDs else { return true }
        session.oversight.autoWakeTargetSessionIDs = targetSessionIDs
        session.isDirty = true
        scheduleSave(for: endpoint.tabID)
        if var entry = ownerValidatedSessionIndex[endpoint.sessionID] {
            entry.agentSessionLinkAutoWakeTargetSessionIDs = targetSessionIDs
            sessionIndexStore.applyLocalUpsert(entry)
        }
        // Baselines newly selected lanes at the epoch they hold now and retracts an attempt this
        // change made ineligible, both before the republication can observe a target that moved in
        // between.
        agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
        session.monitorObservationSignal.send(())
        return true
    }

    @discardableResult
    func agentSessionLinkSetWaitingOn(
        _ waitingOn: DomainAgentSessionWaitingOn?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID]
        else { return false }
        guard session.oversight.waitingOn != waitingOn else { return true }
        session.oversight.waitingOn = waitingOn
        session.monitorObservationSignal.send(())
        return true
    }

    func agentSessionLinkClearWaitingOnAfterAcceptedTurn(_ session: TabSession) {
        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
    }

    func agentSessionLinkStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkStatusProjection? {
        guard let session = sessions[candidate.tabID] else { return nil }
        return Self.statusProjection(for: session)
    }

    /// Single source of truth for observed status.
    ///
    /// Both the narrow UI projection and the full agent-facing snapshot derive from this, so the two
    /// surfaces cannot report different states for the same session.
    static func statusProjection(for session: TabSession) -> AgentSessionLinkStatusProjection {
        let pendingInteraction = pendingInteractionKind(for: session)
        return AgentSessionLinkStatusProjection(
            status: linkStatus(for: session, pendingInteraction: pendingInteraction),
            pendingInteractionKind: pendingInteraction,
            lastActivityAt: session.lastActivityAt
        )
    }

    /// Full agent-facing snapshot, including the redacted assistant preview.
    ///
    /// Reserved for target publication and `poll`; UI rendering must use `statusProjection` instead.
    static func observationSnapshot(
        for session: TabSession,
        candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot {
        let projection = statusProjection(for: session)
        return DomainAgentSessionObservationSnapshot(
            sessionID: candidate.sessionID,
            displayName: candidate.displayName,
            providerDisplayName: candidate.providerDisplayName,
            status: projection.status,
            idleForSend: isIdleForSend(
                session: session,
                candidate: candidate,
                status: projection.status
            ),
            waitingOn: session.oversight.waitingOn,
            pendingInteractionKind: projection.pendingInteractionKind,
            latestVisibleAssistantPreview: latestVisibleAssistantPreview(for: session),
            visibleRowCount: session.transcriptCanonicalVisibleRowCount,
            lastActivityAt: session.lastActivityAt
        )
    }

    /// Installs the tab-scoped observation for one overseen target.
    ///
    /// The merged input set is explicit and includes both review publishers. Non-`@Published`
    /// readiness inputs reach the merge through `monitorObservationSignal`, which is the only way
    /// terminal-commit, follow-up/steering/composer-queue, binding-transition, and hydration changes
    /// can wake an observer.
    func agentSessionLinkInstallObservation(
        for candidate: AgentSessionLinkEndpointCandidate,
        onChange: @escaping @MainActor () -> Void
    ) -> AgentSessionLinkObservationToken? {
        guard let session = sessions[candidate.tabID],
              session.activeAgentSessionID == candidate.sessionID
        else {
            return nil
        }

        let publishers: [AnyPublisher<Void, Never>] = [
            session.$runState.map { _ in () }.eraseToAnyPublisher(),
            session.$items.map { _ in () }.eraseToAnyPublisher(),
            session.$waitingPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingAskUser.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingUserInputRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingPermissionsRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingMCPElicitationRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApplyEditsReview.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingWorktreeMergeReview.map { _ in () }.eraseToAnyPublisher(),
            session.monitorObservationSignal.eraseToAnyPublisher()
        ]

        let cancellable = Publishers.MergeMany(publishers)
            // `@Published` fires in `willSet`, so the snapshot must be built on a later turn to read
            // settled state. `DispatchQueue.main` rather than `RunLoop.main`: a run-loop scheduler
            // only runs in `.default` mode, so target publications would stall for the whole duration
            // of a menu tracking session, a scroll/drag, or a modal sheet in the target window. Main
            // queue blocks are serviced in every run-loop mode.
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated { onChange() }
            }
        return AgentSessionLinkObservationToken { cancellable.cancel() }
    }

    /// Stores an Oversee projection for one **exact incarnation** and republishes the status-pill
    /// snapshot when it belongs to the tab currently on screen.
    ///
    /// Keyed by endpoint rather than by session UUID: an in-place rebind keeps the UUID while
    /// advancing the binding generations, so a UUID-keyed cache would let a fresh incarnation inherit
    /// — or overwrite — another incarnation's outbound rows, inbound names, and notices until the
    /// next refresh happened to correct it.
    func agentSessionLinkPublishProjection(
        _ props: AgentMonitorPillProps,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        // The key is authoritative: stamping it onto the value too keeps the dismissal action the
        // view performs from ever addressing a different incarnation than the rows it is showing.
        var props = agentSessionLinkOverlayingAutoWakePolicy(props, endpoint: endpoint)
        props.endpoint = endpoint
        // One tab of one window holds at most one live incarnation
        // (`agentSessionLinkObserverEndpoint(tabID:)` resolves exactly one), so any *other* entry
        // filed under this tab is a superseded incarnation that nothing can read again. Collecting it
        // here rather than waiting for the tab to close is what keeps repeated in-place rebinds from
        // accumulating one unreachable projection per binding generation: the close-time sweep is the
        // only other collector, and a rebind never closes the tab.
        let superseded = monitorPillPropsByEndpoint.keys.filter { cached in
            cached.tabID == endpoint.tabID && cached != endpoint
        }
        agentSessionLinkMutateProjectionStorage { stored in
            for stale in superseded {
                stored.removeValue(forKey: stale)
            }
            stored[endpoint] = props
        }
    }

    /// Applies one logical exact-projection storage transaction and publishes one presentation
    /// invalidation only after every write and removal is visible.
    ///
    /// This is the sole mutation boundary for `monitorPillPropsByEndpoint`. The status-pill snapshot
    /// is synchronized before the notification so every consumer can immediately re-read the same
    /// completed state. Equal replacements are true no-ops and publish nothing.
    private func agentSessionLinkMutateProjectionStorage(
        _ mutation: (inout [DomainAgentSessionLinkEndpointIdentity: AgentMonitorPillProps]) -> Void
    ) {
        var updated = monitorPillPropsByEndpoint
        mutation(&updated)
        guard updated != monitorPillPropsByEndpoint else { return }
        monitorPillPropsByEndpoint = updated
        syncStatusPillsUIState()
        NotificationCenter.default.post(
            name: .agentSessionLinkOverseerProjectionDidChange,
            object: self
        )
    }

    /// Whether the tab's exact current incarnation is presently overseeing at least one target.
    ///
    /// A session UUID match is insufficient: an in-place rebind advances the endpoint generations,
    /// and a projection addressed to the retired incarnation must fail closed.
    func agentSessionLinkIsOverseer(tabID: UUID, expectedSessionID: UUID) -> Bool {
        guard sessions[tabID]?.activeAgentSessionID == expectedSessionID,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: tabID),
              let props = monitorPillPropsByEndpoint[endpoint],
              props.endpoint == endpoint
        else {
            return false
        }
        return props.isOverseer
    }

    /// Convenience for callers that already hold a live tab identity.
    func agentSessionLinkIsOverseer(tabID: UUID) -> Bool {
        guard let sessionID = sessions[tabID]?.activeAgentSessionID else { return false }
        return agentSessionLinkIsOverseer(tabID: tabID, expectedSessionID: sessionID)
    }

    /// Current target-centric oversight choices for one exact active sidebar row.
    ///
    /// The tab and session checks reject stale sidebar snapshots, while the two endpoint checks keep
    /// an in-place rebind from inheriting either the enclosing projection or its target menu.
    func agentSidebarOversightMenuProps(
        tabID: UUID,
        expectedSessionID: UUID
    ) -> AgentSidebarOversightMenuProps? {
        guard let endpoint = agentSidebarOversightTargetEndpoint(
            tabID: tabID,
            expectedSessionID: expectedSessionID
        ),
            let props = monitorPillPropsByEndpoint[endpoint],
            props.endpoint == endpoint,
            let menu = props.sidebarOversightMenu,
            menu.targetEndpoint == endpoint,
            menu.targetSessionID == expectedSessionID
        else {
            return nil
        }
        return menu
    }

    /// Exact current endpoint behind one active sidebar row, independent of whether its target menu
    /// is presently projectable. System menus can outlive a rebind, so action feedback uses this
    /// identity to distinguish same-endpoint eligibility churn from a replacement incarnation.
    func agentSidebarOversightTargetEndpoint(
        tabID: UUID,
        expectedSessionID: UUID
    ) -> DomainAgentSessionLinkEndpointIdentity? {
        guard sessions[tabID]?.activeAgentSessionID == expectedSessionID else { return nil }
        return agentSessionLinkObserverEndpoint(tabID: tabID)
    }

    /// Adds one exact current overseer to one exact target through the shared establishment core.
    func addAgentSidebarOversight(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSidebarOversightActionOutcome {
        switch await AgentSessionLinkRuntimeBridge.shared.addSidebarMonitorLink(
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint
        ) {
        case .added:
            .changed
        case .alreadyLinked:
            .alreadyInRequestedState
        case let .failed(failure):
            .failed(message: failure.uiMessage)
        case let .rejected(message):
            .failed(message: message)
        }
    }

    /// Removes only the captured generation-qualified observer-target relationship.
    func stopAgentSidebarOversight(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> AgentSidebarOversightActionOutcome {
        switch await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint,
            expectedReference: expectedReference
        ) {
        case .stopped:
            .changed
        case .alreadyStopped:
            .alreadyInRequestedState
        case let .failed(message):
            .failed(message: message)
        }
    }

    /// Overlays this observer's own Auto-wake policy onto the authoritative link rows.
    ///
    /// Projection only, and deliberately applied here rather than inside the link projection itself:
    /// snooze and effective selection live on the exact observer session, not in the link authority,
    /// and the two change on different schedules. Nothing in this method mutates policy, removes an
    /// elapsed record, arms a deadline, or re-enters the wake pipeline — the snooze read it uses is
    /// the coordinator's pure projection, which answers "no snooze" for a record whose monotonic
    /// deadline has passed whether or not bookkeeping has caught up.
    private func agentSessionLinkOverlayingAutoWakePolicy(
        _ props: AgentMonitorPillProps,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentMonitorPillProps {
        guard !props.outbound.isEmpty,
              let session = sessions[endpoint.tabID],
              session.activeAgentSessionID == endpoint.sessionID
        else {
            return props
        }
        // The same rule the coordinator admits lanes by. Read live from the session rather than from
        // the props being published, so a selection written in this same pass cannot render a frame
        // late.
        let oversight = session.oversight
        let outbound = props.outbound.map { row in
            let reference = DomainAgentSessionLinkReference(
                linkID: row.linkID,
                generation: row.generation
            )
            let projection: AgentSessionLinkAutoWakeSnoozeProjection? = switch agentSessionLinkAutoWakeSnoozeProjection(
                endpoint: endpoint,
                targetSessionID: row.targetSessionID,
                expectedReference: reference
            ) {
            case let .success(value):
                value
            case .failure:
                // A row whose exact pairing no longer resolves renders as unsnoozed rather than
                // inheriting a predecessor's suppression.
                nil
            }
            return row.withAutoWakeState(
                snooze: projection.map {
                    AgentMonitorAutoWakeSnoozeState(
                        // Quantized to a whole second because the projection derives it from wall time
                        // at read: two publications a few milliseconds apart would otherwise produce
                        // unequal props and repaint the dashboard for nothing.
                        expiresAt: Date(
                            timeIntervalSince1970: $0.expiresAt.timeIntervalSince1970.rounded()
                        ),
                        origin: $0.origin
                    )
                },
                isEffectivelySelected: oversight.isLaneEffectivelySelected(
                    targetSessionID: row.targetSessionID
                )
            )
        }
        guard outbound != props.outbound else { return props }
        return AgentMonitorPillProps(
            sessionID: props.sessionID,
            endpoint: props.endpoint,
            sidebarOversightMenu: props.sidebarOversightMenu,
            outbound: outbound,
            inbound: props.inbound,
            recentNotices: props.recentNotices,
            canAddReason: props.canAddReason,
            autoWakeOnUpdatesEnabled: props.autoWakeOnUpdatesEnabled,
            autoWakeTargetSessionIDs: props.autoWakeTargetSessionIDs,
            autoWakeUnavailableReason: props.autoWakeUnavailableReason,
            persistence: props.persistence
        )
    }

    /// Eagerly revokes links for tabs whose live binding just disappeared, and drops their stale
    /// Oversee projections.
    ///
    /// Called from the `sessions` `didSet`, so it covers tab close, stash, delete, and MCP control
    /// teardown with one hook. Operation-time identity revalidation still backstops a missed removal.
    ///
    /// Invalidation is `(window, tab)`-scoped, never session-UUID-scoped. One session UUID can be
    /// live in more than one window at once — the resolver models that explicitly — so escalating a
    /// single removed tab to a UUID-wide invalidation would revoke every other window's still-valid
    /// grants for that UUID. The bridge intersects this hint with the live candidate set, so a tab
    /// whose binding merely moved is a no-op.
    func notifyAgentSessionLinkBindingsChanged(previous: [UUID: TabSession]) {
        let closedTabIDs = previous
            .filter { tabID, session in sessions[tabID] == nil && session.activeAgentSessionID != nil }
            .map(\.key)
        guard !closedTabIDs.isEmpty else { return }
        agentSessionLinkPruneProjections()
        for tabID in closedTabIDs {
            AgentSessionLinkInvalidationSink.bindingEnded(
                windowID: windowID,
                tabID: tabID,
                reason: .tabClosed
            )
        }
    }

    /// Every exact incarnation this window currently holds.
    ///
    /// Resolved through the lifecycle identity rather than assembled from `sessions` alone, so it is
    /// the same value space the bridge publishes against.
    func agentSessionLinkLiveEndpoints() -> Set<DomainAgentSessionLinkEndpointIdentity> {
        Set(sessions.keys.compactMap { agentSessionLinkObserverEndpoint(tabID: $0) })
    }

    /// Drops projections whose exact incarnation is no longer live in this window.
    ///
    /// Pruning by endpoint rather than by session UUID is what makes an in-place rebind drop the
    /// previous incarnation's rows: the UUID survives a rebind, so a UUID-scoped sweep would keep a
    /// projection the new incarnation was never granted.
    func agentSessionLinkPruneProjections() {
        let liveEndpoints = agentSessionLinkLiveEndpoints()
        // Prompt state is pruned unconditionally: an observer can lose its binding without ever
        // having had a published pill projection, and a stale acknowledgement would otherwise silence
        // the supplement for a later incarnation reusing the same session UUID.
        agentSessionLinkPrunePromptState(
            liveSessionIDs: Set(sessions.values.compactMap(\.activeAgentSessionID))
        )
        let stale = monitorPillPropsByEndpoint.keys.filter { !liveEndpoints.contains($0) }
        agentSessionLinkMutateProjectionStorage { stored in
            for endpoint in stale {
                stored.removeValue(forKey: endpoint)
            }
        }
    }

    /// Live Add-eligibility inputs for one tab, read synchronously from current session state.
    ///
    /// `hasDurableBinding` is read from the resolved lifecycle identity's
    /// `persistentBindingGeneration`, which is the same predicate the candidate
    /// (`AgentSessionLinkEndpointCandidate.eligibilityInput`), the resolver, and the authority all
    /// use. Deriving it from `activeAgentSessionID` alone was weaker, so Add could enable for a few
    /// frames on a binding the resolver then rejected as `bindingUnresolved`.
    func agentSessionLinkEligibilityInput(
        for session: TabSession,
        tabID: UUID
    ) -> AgentSessionLinkEndpointEligibility.Input {
        let identity = session.activeAgentSessionID.flatMap {
            agentSessionLifecycleIdentity(tabID: tabID, expectedSessionID: $0)
        }
        return AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: identity?.persistentBindingGeneration != nil,
            hasLoadedPersistedState: session.hasLoadedPersistedState,
            isChildSession: session.parentSessionID != nil,
            isMCPControlled: session.mcpControlContext != nil,
            isMCPOriginated: session.isMCPOriginated,
            bindingTransitionInProgress: session.bindingTransitionInProgress,
            // The owning window's `isClosing` is not readable here, but the deletion fence is — and
            // it is the half that matters for this projection: a deletion transition repaints the
            // pill without changing any authority state, so without it the popover would keep
            // offering Add for a transcript that is already being destroyed and rely on the bridge
            // to refuse the action afterwards. Split by permanence, exactly as the candidate is.
            isClosing: session.activeAgentSessionID.map {
                AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: $0)
            } ?? false,
            isDeletionInProgress: session.activeAgentSessionID.map {
                AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: $0)
            } ?? false
        )
    }

    /// Stores the process-wide durable-oversight level and repaints the pill.
    ///
    /// Broadcast to every window, including ones whose tabs hold no links: "saved oversight links
    /// can’t be changed" has to reach the tab that is about to try to create the first one.
    func agentSessionLinkApplyPersistencePresentation(
        _ presentation: AgentSessionOversightPersistencePresentation
    ) {
        guard agentSessionLinkPersistencePresentation != presentation else { return }
        agentSessionLinkPersistencePresentation = presentation
        syncStatusPillsUIState()
    }

    /// Oversee props for the tab currently on screen, or an explicitly disabled projection when the
    /// tab has no durable top-level binding yet.
    func currentMonitorPillProps() -> AgentMonitorPillProps {
        guard let tabID = currentTabID,
              let session = sessions[tabID],
              let sessionID = session.activeAgentSessionID
        else {
            return AgentMonitorPillProps.empty.withPersistence(
                agentSessionLinkPersistencePresentation,
                eligibilityReason: AgentMonitorPillProps.empty.canAddReason
            )
        }
        // Read by the tab's *current* incarnation, resolved synchronously here rather than trusted
        // from whatever was last cached under this session UUID. A rebind that has not yet been
        // republished therefore renders eligibility-only props instead of the previous incarnation's
        // links and notices.
        let published = agentSessionLinkObserverEndpoint(tabID: tabID)
            .flatMap { monitorPillPropsByEndpoint[$0] }
        return Self.monitorPillProps(
            sessionID: sessionID,
            published: published,
            eligibility: agentSessionLinkEligibilityInput(for: session, tabID: tabID),
            roleAllowsOutboundMonitoring: AgentSessionLinkToolPolicy.allowsOutboundMonitoring(
                taskLabelKind: session.mcpControlContext?.taskLabelKind
            ),
            persistence: agentSessionLinkPersistencePresentation
        )
    }

    /// Combines the authoritative link/notice projection with a **synchronously recomputed**
    /// `canAddReason`.
    ///
    /// Eligibility is not link state: hydration finishing or a binding settling changes whether Add
    /// is allowed, but neither produces an authority event. A link-less session whose projection was
    /// published while it was still loading (for example during a full refresh caused by some other
    /// session's link) would otherwise keep "Load this thread before adding sessions to oversee." forever. The
    /// stored props remain authoritative for outbound/inbound rows and notices.
    /// `nonisolated` because it is a pure function of its arguments: it touches no view-model state,
    /// which is what makes the stale-eligibility behaviour testable without building a view model.
    nonisolated static func monitorPillProps(
        sessionID: UUID,
        published: AgentMonitorPillProps?,
        eligibility: AgentSessionLinkEndpointEligibility.Input,
        roleAllowsOutboundMonitoring: Bool,
        persistence: AgentSessionOversightPersistencePresentation = .noDurableLayer
    ) -> AgentMonitorPillProps {
        let eligibilityReason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            eligibility,
            roleAllowsOutboundMonitoring: roleAllowsOutboundMonitoring
        )
        guard let published else {
            return AgentMonitorPillProps(
                sessionID: sessionID,
                sidebarOversightMenu: nil,
                outbound: [],
                inbound: [],
                recentNotices: [],
                // Persistence wins over eligibility: a perfectly eligible session still cannot be
                // granted oversight while the durable record refuses to change.
                canAddReason: persistence.addBlockerMessage ?? eligibilityReason,
                persistence: persistence
            )
        }
        return published.withPersistence(persistence, eligibilityReason: eligibilityReason)
    }

    /// Generation-bearing capture for a Copy Session ID action offered on one row.
    func agentSessionCopyIDTarget(
        tabID: UUID,
        sessionID: UUID,
        tabName: String
    ) -> AgentSessionCopyIDTarget? {
        guard let candidate = agentSessionLinkCandidate(
            tabID: tabID,
            sessionID: sessionID,
            tabName: tabName,
            isWindowClosing: false
        ),
            AgentSessionCopyIDPolicy.isOfferable(candidate)
        else {
            return nil
        }
        return AgentSessionCopyIDTarget(candidate: candidate)
    }

    /// Revalidates a captured Copy Session ID target and, only if it is still the exact same live
    /// incarnation, writes its canonical UUID.
    ///
    /// - Returns: `true` when the clipboard was written. A `false` result means **zero** clipboard
    ///   writes happened, so the caller must not show success feedback.
    @discardableResult
    func copyAgentSessionID(
        target: AgentSessionCopyIDTarget,
        isWindowClosing: Bool = false,
        copyToClipboard: (String) -> Void = AgentSessionCopyIDClipboard.write
    ) -> Bool {
        guard !isWindowClosing else { return false }
        let live = agentSessionLinkCandidates(isWindowClosing: isWindowClosing)
        guard case let .copied(value) = AgentSessionCopyIDPolicy.outcome(
            for: target,
            liveCandidates: live
        ) else {
            return false
        }
        copyToClipboard(value)
        return true
    }

    // MARK: - Pure projections

    static func pendingInteractionKind(
        for session: TabSession
    ) -> DomainAgentSessionLinkPendingInteractionKind? {
        // Ordered most-blocking first so a session with several queued interactions reports the one
        // the user must resolve next.
        if session.pendingApproval != nil { return .approval }
        if session.pendingPermissionsRequest != nil { return .permission }
        if session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil {
            return .review
        }
        if session.pendingAskUser != nil { return .question }
        if session.pendingUserInputRequest != nil || session.pendingMCPElicitationRequest != nil {
            return .input
        }
        return nil
    }

    static func linkStatus(
        for session: TabSession,
        pendingInteraction: DomainAgentSessionLinkPendingInteractionKind?
    ) -> DomainAgentSessionLinkStatus {
        if pendingInteraction != nil || session.waitingPrompt != nil { return .awaitingUser }
        switch session.runState {
        case .running:
            return .running
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return .awaitingUser
        case .idle, .completed, .cancelled, .failed:
            // A completed/cancelled/failed run in a still-live session is idle, not ended. Endpoint
            // closure revokes the link instead of publishing a terminal pollable state.
            return .idle
        }
    }

    /// Conservative send-readiness for the published snapshot.
    ///
    /// The authoritative admission decision belongs to the send transaction; this value only tells an
    /// observer whether attempting a send is currently plausible, so it errs toward `false`.
    ///
    /// Every non-lifecycle blocker `AgentSessionLinkDeliveryReadiness.isTargetBusy` checks must appear
    /// here too. A blocker the readiness matrix enforces but this projection omits publishes
    /// `idle_for_send: true` for a target that `send` will still refuse, and `until: "sendable"` waits
    /// on exactly this field — so an omission turns the documented wait-then-send recipe back into
    /// the retry loop it exists to prevent.
    static func isIdleForSend(
        session: TabSession,
        candidate: AgentSessionLinkEndpointCandidate,
        status: DomainAgentSessionLinkStatus
    ) -> Bool {
        status == .idle
            && !session.runState.isActive
            && session.hasLoadedPersistedState
            && !session.bindingTransitionInProgress
            && !session.terminalCommitInProgress
            && !session.mcpFollowUpRunPending
            && !session.isComposerSubmissionInFlight
            && !session.isPreparingInitialWorktree
            && !session.isChangingExecutionLocation
            && session.pendingInstructions.isEmpty
            && session.pendingACPSteeringInstructions.isEmpty
            && session.pendingClaudeSteeringInstructions.isEmpty
            && session.oversight.pendingAutoWake == nil
            && !candidate.isClosing
    }

    static func latestVisibleAssistantPreview(for session: TabSession) -> String? {
        latestVisibleAssistantPreview(items: session.items)
    }

    /// Redacted preview of the newest finished assistant message.
    ///
    /// Thinking, tool payloads, and streaming fragments are never previewed, and the surviving text
    /// is model-generated prose that can contain anything the target's provider echoed — pasted
    /// credentials, absolute paths, log excerpts. It therefore goes through the same oversight-scoped
    /// redactor the transcript sanitizer uses.
    ///
    /// Redaction happens **here**, before `DomainAgentSessionObservationSnapshot` applies its 280-byte
    /// cap. Capping first would let a secret straddling the boundary survive as a truncated fragment
    /// that the redactor never sees.
    ///
    /// `nonisolated` and item-based so the redaction contract is testable without a view model.
    nonisolated static func latestVisibleAssistantPreview(
        items: [AgentChatItem],
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        for item in items.reversed() {
            guard item.kind == .assistant || item.kind == .assistantInline else { continue }
            guard !item.isStreaming else { continue }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let redacted = AgentSessionLinkTextRedactor
                .redact(trimmed, homeDirectory: homeDirectory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return redacted.isEmpty ? nil : redacted
        }
        return nil
    }
}
