import Foundation
import RepoPromptDomainRuntime

/// Window-local seam between the authoritative link inventory and the provider dispatch adapters.
///
/// The adapters (Codex start/steer/fallback, Claude native, Claude/generic headless, ACP prompt and
/// active steering, waiting-instruction continuation) all reduce to two synchronous MainActor calls:
/// compose immediately before the physical dispatch, acknowledge at the provider's acceptance
/// signal. Keeping the actor hop out of the dispatch path matters — every one of those sites runs
/// while a user turn is already committed, and none of them may block on the domain actor.
/// The authoritative outbound inventory published to one exact incarnation.
///
/// The endpoint is stored alongside the value rather than implied by the map key: an in-place rebind
/// keeps the session UUID while advancing the binding generations, so a UUID-keyed read alone would
/// hand a fresh incarnation the targets the previous one was granted.
struct AgentSessionLinkPublishedPromptInventory: Equatable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let inventory: AgentSessionLinkPromptInventory
}

/// One endpoint's publication fence, raised for the duration of *every* overlapping membership write.
///
/// The fence is shared, not owned: activations for the same observer can overlap (the Add sheet's
/// `isWorking` single-flight is per-view `@State`, so dismissing and reopening it mid-flight yields a
/// fresh control), and it must stay raised until the last participant has settled. A fence that only
/// the newest writer could lower let a *rejected* newest writer restore the pre-hop inventory over a
/// sibling that had already committed but not yet published — the same false terminal notice the
/// fence exists to prevent, reachable in the other release order.
struct AgentSessionLinkPromptInventoryHold: Equatable {
    /// Every writer that has raised this fence and not yet settled. While it is non-empty the
    /// endpoint stays withheld, so no release order can expose a partially-settled membership.
    let outstanding: Set<UInt64>
    /// What this endpoint had published when the *first* participant fenced it, restored only if no
    /// participant commits. `nil` when the endpoint had nothing published, which is itself the
    /// correct state to return to.
    let retracted: AgentSessionLinkPromptInventory?
    /// The highest-`linkSetRevision` inventory reported by a participant that committed, or `nil`
    /// while none has. This is what the last release publishes: it is a comparison of values each
    /// read inside the body that committed it, so it does not depend on which continuation resumes
    /// first.
    let committed: AgentSessionLinkPromptInventory?
}

/// One incarnation's claim inputs: what it may be told, and the epoch that scopes the telling.
struct AgentSessionLinkPromptContext: Equatable {
    let epoch: AgentSessionLinkPromptEpoch
    let inventory: AgentSessionLinkPromptInventory
    /// This session's latest published passive status queue, unfiltered.
    ///
    /// Deliberately handed over raw rather than pre-screened here: every condition that may join a
    /// batch to a dispatch — endpoint match, eligibility, enablement, deliverability, revision match,
    /// and grant membership — lives in one truth table inside the claim store, where it is testable
    /// without a view model.
    let passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?

    init(
        epoch: AgentSessionLinkPromptEpoch,
        inventory: AgentSessionLinkPromptInventory,
        passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot? = nil
    ) {
        self.epoch = epoch
        self.inventory = inventory
        self.passiveNotices = passiveNotices
    }
}

extension AgentModeViewModel {
    enum ProviderInputCatalogReadiness: Equatable {
        case notRequired
        case ready
        case unavailable
        case timedOut
        case superseded
        case cancelled
    }

    private func requiresExactSessionLinkProviderInputCatalog(
        _ agent: AgentProviderKind
    ) -> Bool {
        agent == .codexExec || agent.usesClaudeNativeRuntime
    }

    /// Providers that retain or initialize an MCP catalog before dispatch wait for the exact
    /// server-observed catalog instead of treating client configuration as acknowledgement.
    func ensureProviderInputCatalogReady(
        for session: TabSession,
        timeout: TimeInterval = 2.0
    ) async -> ProviderInputCatalogReadiness {
        guard requiresExactSessionLinkProviderInputCatalog(session.selectedAgent) else { return .notRequired }
        guard sessions[session.tabID] === session,
              let runID = session.runID
        else { return .unavailable }
        // Outbound oversight links are keyed by exact endpoint incarnation. Without one, this run
        // has no oversight route whose provider catalog must be qualified before an ordinary send.
        guard let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID) else { return .notRequired }
        guard let sessionID = session.activeAgentSessionID,
              endpoint.sessionID == sessionID
        else {
            return .unavailable
        }

        let isRequired = await agentSessionLinkHasActiveOutboundLink(endpoint)
        if Task.isCancelled { return .cancelled }
        guard sessions[session.tabID] === session else { return .unavailable }
        guard session.runID == runID,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint
        else {
            return .superseded
        }
        guard isRequired else { return .notRequired }

        let authoritativeRouteToken = await agentSessionLinkAuthoritativeRunCatalogRouteToken(
            runID: runID,
            windowID: endpoint.windowID,
            tabID: session.tabID
        )
        if Task.isCancelled { return .cancelled }
        guard sessions[session.tabID] === session else { return .unavailable }
        guard session.runID == runID,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint
        else {
            return .superseded
        }
        if let current = agentSessionLinkRunCatalogProjectionByEndpoint[endpoint],
           current.runID == runID,
           current.isReady,
           current.routeToken == authoritativeRouteToken,
           authoritativeRouteToken != nil
        {
            return .ready
        }
        let outcome = await ServerNetworkManager.shared.awaitRunCatalogReadiness(
            runID: runID,
            observerEndpoint: endpoint,
            expectedRouteToken: authoritativeRouteToken,
            timeout: timeout
        )
        switch outcome {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .superseded:
            return .superseded
        case let .ready(ready):
            let remainsRequired = await agentSessionLinkHasActiveOutboundLink(endpoint)
            if Task.isCancelled { return .cancelled }
            guard sessions[session.tabID] === session else { return .unavailable }
            guard session.runID == runID,
                  agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint
            else {
                return .superseded
            }
            guard remainsRequired else { return .notRequired }
            let authoritativeRouteToken = await agentSessionLinkAuthoritativeRunCatalogRouteToken(
                runID: runID,
                windowID: endpoint.windowID,
                tabID: session.tabID
            )
            if Task.isCancelled { return .cancelled }
            guard sessions[session.tabID] === session else { return .unavailable }
            guard session.runID == runID,
                  agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint
            else {
                return .superseded
            }
            guard let authoritativeRouteToken,
                  let applied = agentSessionLinkRunCatalogProjectionByEndpoint[endpoint],
                  applied.runID == runID,
                  applied.projectionRevision >= ready.projectionRevision,
                  applied.isReady,
                  applied.routeToken == authoritativeRouteToken
            else {
                return .unavailable
            }
            return .ready
        }
    }

    private func agentSessionLinkHasActiveOutboundLink(
        _ endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> Bool {
        #if DEBUG
            if let test_agentSessionLinkHasActiveOutboundLink {
                return await test_agentSessionLinkHasActiveOutboundLink(endpoint)
            }
        #endif
        return await AgentSessionLinkRuntimeBridge.shared.hasActiveOutboundLink(
            observerEndpoint: endpoint
        )
    }

    private func agentSessionLinkAuthoritativeRunCatalogRouteToken(
        runID: UUID,
        windowID: Int,
        tabID: UUID
    ) async -> AgentSessionLinkRunCatalogRouteToken? {
        #if DEBUG
            if let test_agentSessionLinkAuthoritativeRunCatalogRouteToken {
                return await test_agentSessionLinkAuthoritativeRunCatalogRouteToken(runID, windowID, tabID)
            }
        #endif
        return await ServerNetworkManager.shared.authoritativeRunCatalogRouteToken(
            runID: runID,
            windowID: windowID,
            tabID: tabID
        )
    }

    /// Synchronous final fence for providers whose MCP catalog can outlive or race a connection.
    /// The async readiness query proves policy/lifecycle authority; this last check proves that the
    /// exact connection it qualified still owns the MainActor route at composition time.
    func agentSessionLinkHasCurrentProviderInputCatalogRoute(for session: TabSession) -> Bool {
        guard requiresExactSessionLinkProviderInputCatalog(session.selectedAgent) else { return true }
        guard sessions[session.tabID] === session,
              let runID = session.runID,
              let sessionID = session.activeAgentSessionID,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              endpoint.sessionID == sessionID,
              let projection = agentSessionLinkRunCatalogProjectionByEndpoint[endpoint],
              projection.runID == runID,
              projection.isReady,
              let routeToken = projection.routeToken,
              routeToken.observerEndpoint == endpoint
        else { return false }
        #if DEBUG
            if let test_agentSessionLinkCurrentRunCatalogRouteToken {
                return test_agentSessionLinkCurrentRunCatalogRouteToken(routeToken, session.tabID)
            }
            // Existing synthetic readiness fixtures replace the async authority query without
            // installing a real MCP mapping. They may opt into the stricter synchronous seam when
            // exercising handover behavior; otherwise the synthetic token is their authority.
            if test_agentSessionLinkAuthoritativeRunCatalogRouteToken != nil {
                return true
            }
        #endif
        return hasCurrentRunCatalogRouteTokenInCurrentMCPServer(
            routeToken,
            tabID: session.tabID
        )
    }

    // MARK: - Inventory publication

    /// Stores the authoritative outbound inventory for one exact endpoint incarnation.
    ///
    /// The ordinary publication path: the runtime bridge's projection refresh, which rebuilds this
    /// alongside Oversee's UI rows. The two are emitted from the same pass, but they are *not* one
    /// atomic update — see `agentSessionLinkWithholdPromptInventory(for:)`: a membership write fences
    /// this value and republishes it from the write's own disposition, ahead of the refresh that
    /// later rebuilds the pill. For a brief interval the prompt inventory can therefore be newer than
    /// the pill. That direction is deliberate: the pill lagging costs one stale row, whereas the
    /// prompt lagging costs a false statement to a model.
    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        agentSessionLinkWritePromptInventory(inventory, to: endpoint, releasing: nil)
    }

    /// Applies one publication, subject to the two rules every publisher shares.
    ///
    /// 1. **A fenced endpoint stays fenced.** An ordinary publication carries an inventory read from
    ///    the authority at some earlier instant; if a membership write raised the fence after that
    ///    read, the value in hand is already known to be about to stop being true. Only the write
    ///    that raised a fence may publish through it.
    /// 2. **No incarnation moves backwards.** `linkSetRevision` advances on every membership change
    ///    for this observer and is never reset, so a lower revision for the same endpoint is stale by
    ///    construction. Equal revisions are accepted: display names refresh without a membership
    ///    change, and those must still land.
    ///
    /// Rule 2 protects an *already published* value from a stale write, which is exactly what it
    /// cannot do while the endpoint is withheld: the retraction removed the entry there is nothing
    /// left to compare against. Overlapping writes are therefore not made safe here — they are made
    /// safe by the fence outliving all of them and by the highest-revision comparison the hold itself
    /// carries (see `AgentSessionLinkPromptInventoryHold.committed`). Both are comparisons; neither
    /// assumes a resumption order.
    private func agentSessionLinkWritePromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity,
        releasing token: UInt64?
    ) {
        if token == nil, agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] != nil { return }
        let existing = agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID]
        if let existing,
           existing.endpoint == endpoint,
           existing.inventory.linkSetRevision > inventory.linkSetRevision
        {
            return
        }
        let published = AgentSessionLinkPublishedPromptInventory(
            endpoint: endpoint,
            inventory: inventory
        )
        if existing == published { return }
        agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID] = published
        // An accepted publication names the incarnation this session UUID currently *is*, so a passive
        // queue filed under that UUID for any other incarnation belongs to a retired one. Collected
        // here rather than in the prune sweep because a rebind keeps the UUID alive: the sweep would
        // never drop it, and the replacement incarnation starts with no queue of its own to overwrite
        // it with.
        if let passive = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           passive.observerEndpoint != endpoint
        {
            agentSessionLinkPassiveNoticesBySessionID.removeValue(forKey: endpoint.sessionID)
        }
    }

    /// Applies a server-observed catalog projection without allowing a late callback to move backward.
    func agentSessionLinkPublishRunCatalogProjection(
        _ projection: AgentSessionLinkRunCatalogProjection,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        func record(_ outcome: AgentSessionLinkCatalogDiagnostics.Outcome) {
            AgentSessionLinkCatalogDiagnostics.projectionEvaluated(
                runID: projection.runID,
                tabID: endpoint.tabID,
                revision: projection.projectionRevision,
                catalog: projection.hasAgentSessionLink,
                outbound: projection.hasActiveOutboundLink,
                outcome: outcome
            )
        }

        guard projection.routeToken?.observerEndpoint == endpoint else {
            record(.rejectedEndpointMismatch)
            return
        }
        guard let session = sessions[endpoint.tabID] else {
            record(.rejectedMissingSession)
            return
        }
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint else {
            record(.rejectedEndpointRebind)
            return
        }
        guard session.runID == projection.runID else {
            record(.rejectedRunMismatch)
            return
        }

        let existing = agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]
        if let existing,
           existing.runID == projection.runID,
           existing.projectionRevision > projection.projectionRevision
        {
            record(.rejectedStaleRevision)
            return
        }
        if existing == projection {
            record(.coalescedDuplicate)
            return
        }

        record(.accepted)
        let becameReady = projection.isReady && !(existing?.runID == projection.runID && existing?.isReady == true)
        agentSessionLinkRunCatalogProjectionByEndpoint[endpoint] = projection
        if projection.isReady {
            requestUIRefresh(tabID: endpoint.tabID, urgent: true)
        }
        if becameReady,
           let passive = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           passive.observerEndpoint == endpoint
        {
            agentSessionLinkNoteAutoWakeOpportunity(passive, endpoint: endpoint)
        }
        agentSessionLinkReconcileCodexCatalogRepair(projection, session: session)
    }

    /// Opens, holds, or closes the Codex session-link catalog-repair episode for one exact accepted
    /// projection.
    ///
    /// The condition being recognized is a *returned* catalog that says `agent_session_link` is
    /// absent while the link authority says this exact endpoint still holds a live outbound grant.
    /// `notifyToolListChangedForAgentSession` republishes precisely that pair when a restored grant
    /// activates against a run whose client has not yet re-read `tools/list`, and
    /// `agentSessionLinkPromptContext` then fails closed for the whole established run — so Auto-wake
    /// is blocked behind a projection nothing in the existing pipeline can heal.
    ///
    /// Opening belongs here rather than in the coordinator because this is the only frame where the
    /// mismatch and the projection storage that produced it are visible in one synchronous MainActor
    /// step. Writing the marker *before* invoking the coordinator is what makes the open atomic: a
    /// nested or reentrant publication cannot reopen the same episode.
    ///
    /// Route currency is deliberately not re-derived, and `projection.isReady` is deliberately not
    /// used — the state being recognized is intentionally unready. What the publish guard above
    /// actually proves is *identity*: the projection carries a route token naming this tab's current
    /// endpoint, for this session object's current run, at a revision no lower than the stored one.
    /// It does not prove that the observing connection still owns the authoritative route at the
    /// moment this side effect runs; only `hasCurrentRunCatalogRouteTokenInCurrentMCPServer` proves
    /// that, and it additionally requires the positive catalog presence this state by definition
    /// lacks.
    ///
    /// The accepted bound is therefore that a projection published for the current endpoint and run
    /// may already be one connection generation stale by the time the repair runs. The cost is
    /// bounded to one controller replacement for a session that was going to reconnect anyway, and
    /// the episode marker prevents it from repeating; the alternative — an authority round trip on
    /// every unready publication — buys a fresher answer that can go stale the same way.
    private func agentSessionLinkReconcileCodexCatalogRepair(
        _ projection: AgentSessionLinkRunCatalogProjection,
        session: TabSession
    ) {
        // Only an exact current observation closes an episode. Unknown presence — a route torn down
        // or not yet observed — leaves it open, because it is not evidence that the catalog healed.
        if projection.hasAgentSessionLink == true || projection.hasActiveOutboundLink == false {
            let hadEpisode = session.codexSessionLinkCatalogRepairSourceGeneration != nil
            session.codexSessionLinkCatalogRepairSourceGeneration = nil
            if hadEpisode {
                AgentSessionLinkCatalogDiagnostics.repairTransition(
                    runID: projection.runID,
                    tabID: session.tabID,
                    outcome: projection.hasAgentSessionLink == true ? .closedCatalogPresent : .closedOutboundLost
                )
            }
            return
        }
        guard session.selectedAgent == .codexExec,
              projection.hasAgentSessionLink == false,
              projection.hasActiveOutboundLink == true,
              session.codexController != nil,
              // Disablement is a reason not to repair, never a reason to reconnect: the returned
              // catalog is then truthfully absent and the user asked for that.
              ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.agentSessionLink)
        else {
            return
        }
        if session.codexSessionLinkCatalogRepairSourceGeneration == nil {
            session.codexSessionLinkCatalogRepairSourceGeneration = session.codexControllerGeneration
            AgentSessionLinkCatalogDiagnostics.repairTransition(
                runID: projection.runID,
                tabID: session.tabID,
                outcome: .opened
            )
        }
        codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: session)
    }

    /// Stores one exact incarnation's passive status-notice queue.
    ///
    /// Endpoint-matched twice, because the snapshot is the input to an agent-facing payload: it has
    /// to name the incarnation it was reduced for, and that incarnation has to still be the one this
    /// tab holds. A rebound tab reusing the same session UUID is therefore refused the previous
    /// incarnation's queue rather than inheriting it.
    ///
    /// Queue revisions are monotonic within one epoch, so a late publication carrying an older
    /// revision of the same epoch is dropped rather than allowed to resurrect entries a receipt has
    /// already removed.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard snapshot.observerEndpoint == endpoint,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else {
            return
        }
        if let existing = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           existing.observerEndpoint == endpoint,
           existing.queueEpoch == snapshot.queueEpoch,
           existing.queueRevision > snapshot.queueRevision
        {
            return
        }
        agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID] = snapshot
        // This is also the auto-wake scheduling hint. Deliberately the same endpoint-addressed hook
        // rather than a second channel: whatever publishes deliverable content is exactly what a wake
        // would be scheduled against, and whatever clears it is exactly what cancels one.
        agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
    }

    /// Fences one exact incarnation's prompt inventory and retracts its published value.
    ///
    /// The bridge raises this immediately before an authority membership write and lowers it from the
    /// write's own disposition. While it is up, `agentSessionLinkPromptContext` fails its existing
    /// `published` guard and every claim returns `nil` — no new suppression concept, and in
    /// particular nothing that reaches `AgentSessionLinkPromptSupplementDecision`, whose
    /// `isEligibilitySuppressed` stays the sole classifier of *why* an inventory is empty. A window
    /// with no published inventory is not an empty inventory; it is the absence of an answer, and the
    /// supplement simply stays owed to the next dispatch.
    ///
    /// Retraction alone is not the fence, which is the correction this round makes: the map is
    /// repopulated by whichever publisher runs next, and the ordinary projection refresh can be
    /// suspended on the authority hop holding an inventory it read *before* the retraction. Removing
    /// the value fences the reader; the recorded hold is what fences the writers.
    ///
    /// Endpoint-matched before retracting: a stale bridge call naming a superseded incarnation must
    /// not take the current one's inventory. The fence itself is still recorded for the named
    /// endpoint — that endpoint is the one about to gain a grant, and it is the one whose stale
    /// publication would lie.
    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64 {
        agentSessionLinkNextPromptInventoryHoldToken &+= 1
        let token = agentSessionLinkNextPromptInventoryHoldToken
        // An overlapping write *joins* the existing fence rather than replacing it: the baseline to
        // restore is still the value actually published before any of them started, and a sibling's
        // already-recorded commit must not be forgotten by the writer that arrives after it.
        if let existing = agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] {
            agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
                outstanding: existing.outstanding.union([token]),
                retracted: existing.retracted,
                committed: existing.committed
            )
            return token
        }
        var retracted: AgentSessionLinkPromptInventory?
        if let published = agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID],
           published.endpoint == endpoint
        {
            retracted = published.inventory
            agentSessionLinkPromptInventoryBySessionID.removeValue(forKey: endpoint.sessionID)
        }
        agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
            outstanding: [token],
            retracted: retracted,
            committed: nil
        )
        return token
    }

    /// Settles `token`'s participation in the fence, lowering it only once every participant has
    /// settled.
    ///
    /// `inventory` is the membership the write itself observed, read inside the same actor-isolated
    /// body that committed it; `nil` means the write did not commit.
    ///
    /// The last release decides what the endpoint publishes, and it decides it by revision, not by
    /// arrival: the highest-revision inventory any participant committed, or — if none committed —
    /// the value the first withhold retracted. That is what makes both release orders safe. A
    /// rejection landing *after* a sibling's commit cannot restore the pre-hop inventory, because the
    /// sibling's commit is recorded in the hold; a rejection landing *before* it cannot either,
    /// because the fence stays up and the sibling's own release publishes through it. Neither path
    /// assumes which continuation the MainActor resumes first — Swift guarantees no such order for
    /// resumptions after separate `await`s.
    ///
    /// A release whose token the fence no longer tracks (the endpoint was pruned mid-write, or the
    /// same token is released twice) still publishes a committed inventory, which is exact as of its
    /// own commit and bounded by rule 2 of `agentSessionLinkWritePromptInventory`. It restores
    /// nothing: with no fence left to speak for, its baseline is not the current truth.
    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        guard let token else { return }
        guard let hold = agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint],
              hold.outstanding.contains(token)
        else {
            if let inventory {
                agentSessionLinkWritePromptInventory(inventory, to: endpoint, releasing: token)
            }
            return
        }
        var outstanding = hold.outstanding
        outstanding.remove(token)
        let committed = agentSessionLinkNewerCommittedInventory(hold.committed, inventory)
        guard outstanding.isEmpty else {
            agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
                outstanding: outstanding,
                retracted: hold.retracted,
                committed: committed
            )
            return
        }
        agentSessionLinkPromptInventoryHoldsByEndpoint.removeValue(forKey: endpoint)
        guard let value = committed ?? hold.retracted else { return }
        agentSessionLinkWritePromptInventory(value, to: endpoint, releasing: token)
    }

    /// The committed candidate the fence should carry forward, by revision.
    ///
    /// Ties go to `new`: equal revisions mean the same membership, and the later report of it is the
    /// one whose display names are current — the same reason rule 2 accepts an equal revision.
    private func agentSessionLinkNewerCommittedInventory(
        _ existing: AgentSessionLinkPromptInventory?,
        _ new: AgentSessionLinkPromptInventory?
    ) -> AgentSessionLinkPromptInventory? {
        guard let new else { return existing }
        guard let existing else { return new }
        return new.linkSetRevision >= existing.linkSetRevision ? new : existing
    }

    /// Drops prompt state for sessions whose live binding disappeared.
    ///
    /// A re-opened session reusing the same UUID is a new incarnation: it must start from "never
    /// acknowledged" so it is taught oversight again rather than inheriting a stale acknowledgement.
    func agentSessionLinkPrunePromptState(liveSessionIDs: Set<UUID>) {
        for (sessionID, published) in agentSessionLinkPromptInventoryBySessionID
            where agentSessionLinkObserverEndpoint(tabID: published.endpoint.tabID) != published.endpoint
        {
            agentSessionLinkPromptInventoryBySessionID.removeValue(forKey: sessionID)
        }
        // A fence outlives its writer only if the endpoint died mid-write, where the claim path
        // already fails closed on endpoint resolution. Dropping it keeps a dead endpoint from
        // permanently withholding a supplement from a session that reuses its slot.
        for endpoint in agentSessionLinkPromptInventoryHoldsByEndpoint.keys
            where agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) != endpoint
        {
            agentSessionLinkPromptInventoryHoldsByEndpoint.removeValue(forKey: endpoint)
        }
        for endpoint in agentSessionLinkRunCatalogProjectionByEndpoint.keys
            where agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) != endpoint
        {
            agentSessionLinkRunCatalogProjectionByEndpoint.removeValue(forKey: endpoint)
        }
        // Pruned on the same schedule as the inventory it is joined to: a queue left behind for a
        // dead session would be matched against a later incarnation's revision by coincidence rather
        // than by proof.
        for (sessionID, passive) in agentSessionLinkPassiveNoticesBySessionID
            where agentSessionLinkObserverEndpoint(tabID: passive.observerEndpoint.tabID) != passive.observerEndpoint
        {
            agentSessionLinkPassiveNoticesBySessionID.removeValue(forKey: sessionID)
        }
        // An endpoint that disappeared or rebound must not keep a reservation: the replacement
        // incarnation starts fresh, and a task still waiting on the dead one would otherwise hold
        // `idle_for_send` false for a session nothing is going to wake.
        for (tabID, session) in sessions {
            guard let attempt = session.pendingOversightAutoWake else { continue }
            guard !liveSessionIDs.contains(attempt.observerEndpoint.sessionID)
                || agentSessionLinkObserverEndpoint(tabID: tabID) != attempt.observerEndpoint
            else {
                continue
            }
            cancelAgentSessionLinkAutoWake(
                for: attempt.observerEndpoint,
                reason: .endpointInvalidated
            )
        }
        // Snooze state retires on the same schedule and for the same reason: it is keyed by exact
        // observer incarnation, so a rebind, unlink, replacement, or teardown must drop it and
        // invalidate its deadline token rather than let a successor inherit suppression it never
        // asked for. Accepted-provenance-before-receipt ordering is untouched by this.
        agentSessionLinkPruneAutoWakeSnoozeState()
        agentSessionLinkPromptClaimStore.retainOnly(observerSessionIDs: liveSessionIDs)
    }

    // MARK: - Effective inventory

    /// The compose tab currently holding *this exact* session object, or `nil`.
    ///
    /// Object identity, not session UUID: the epoch below has to name one exact incarnation, and a
    /// tab whose session was replaced can still carry the same UUID.
    private func agentSessionLinkTabID(for session: TabSession) -> UUID? {
        let tabID = session.tabID
        guard sessions[tabID] === session else { return nil }
        return tabID
    }

    /// The inventory this exact incarnation may be told about, plus the epoch scoping its claims.
    ///
    /// Three fail-closed gates, in order: the tab must still hold this session object, the endpoint
    /// must still resolve, and the published inventory must have been addressed to *that* endpoint.
    /// The last one is what stops a rebound tab from inheriting the previous incarnation's targets
    /// during the window before the bridge republishes.
    ///
    /// A session whose effective role cannot perform outbound observer operations is reported as
    /// having no outbound inventory, even if an inbound link keeps the shared tool visible. The
    /// revision is preserved, which keeps the closing path intact: an observer that already accepted
    /// a real inventory and then lost eligibility still gets exactly one closing notice.
    ///
    /// The eligibility bit travels with the epoch rather than being left implicit in the emptied
    /// inventory, and both are computed from the single `input` below. That pairing is load-bearing:
    /// this function is the layer that collapses a non-empty authoritative membership to an empty
    /// effective one, so without the bit the claim store cannot tell "hidden because ineligible" from
    /// "actually empty" — and it used to guess, from revision movement, that a partial membership
    /// change during a suppressed window meant the observer's last link was gone.
    func agentSessionLinkPromptContext(for session: TabSession) -> AgentSessionLinkPromptContext? {
        guard let sessionID = session.activeAgentSessionID,
              let tabID = agentSessionLinkTabID(for: session),
              let endpoint = agentSessionLinkObserverEndpoint(tabID: tabID),
              endpoint.sessionID == sessionID,
              let published = agentSessionLinkPromptInventoryBySessionID[sessionID],
              published.endpoint == endpoint
        else {
            return nil
        }
        let input = AgentSessionLinkPromptEligibility.Input(
            isChildSession: session.parentSessionID != nil,
            isMCPControlled: session.mcpControlContext != nil,
            isMCPOriginated: session.isMCPOriginated,
            roleAllowsOutboundMonitoring: AgentSessionLinkToolPolicy.allowsOutboundMonitoring(
                taskLabelKind: session.mcpControlContext?.taskLabelKind
            )
        )
        let effectiveInventory = AgentSessionLinkPromptEligibility.effectiveInventory(
            published.inventory,
            input: input
        )
        // A missing process-local run identifies pre-run bootstrap: the wake this context admits is
        // what creates the run and its catalog. Once any run exists, keep requiring its exact ready
        // catalog and provider-input route; a stale or unready established run still fails closed.
        if !effectiveInventory.items.isEmpty, let runID = session.runID {
            guard let catalog = agentSessionLinkRunCatalogProjectionByEndpoint[endpoint],
                  catalog.runID == runID,
                  catalog.isReady,
                  catalog.routeToken?.observerEndpoint == endpoint
            else {
                return nil
            }
            guard agentSessionLinkHasCurrentProviderInputCatalogRoute(for: session) else {
                return nil
            }
        }
        return AgentSessionLinkPromptContext(
            epoch: AgentSessionLinkPromptEpoch(
                endpoint: endpoint,
                allowsSupplement: AgentSessionLinkPromptEligibility.allowsSupplement(input),
                // Computed once, here, and carried on the epoch: the provider decides the
                // model-visible tool name a fragment must use, and it is also what makes a cached
                // fragment stale when the session is rebound to a different runtime. Deriving it
                // separately at render time is how the two could disagree.
                agentKind: session.selectedAgent
            ),
            inventory: effectiveInventory,
            passiveNotices: agentSessionLinkPassiveNoticesBySessionID[sessionID]
        )
    }

    /// The inventory this session may actually be told about, without its epoch.
    func agentSessionLinkEffectivePromptInventory(
        for session: TabSession
    ) -> AgentSessionLinkPromptInventory? {
        agentSessionLinkPromptContext(for: session)?.inventory
    }

    // MARK: - Claim and acceptance

    /// Reserves the supplement owed to `session` for one logical dispatch, rendering it against the
    /// **current** membership revision.
    ///
    /// A revision-stable retry of the same `dispatchID` gets its existing claim back; a membership
    /// change since the claim was made abandons it and renders the current one instead.
    /// A dispatch made *by* an auto-wake claims under that wake's own identity.
    ///
    /// This substitution is the single provider-neutral seam: the wake decides to start a turn before
    /// it knows which route that turn will take, and each family mints its own dispatch ID inside the
    /// run. Rewriting the ID here means Codex, Claude native, ACP, and headless all produce a claim
    /// stamped `lane.autowake:<wakeID>` without any of them learning what a lane update is — and it is
    /// that stamp, not mutable session state, that later decides what the acceptance signal settles.
    ///
    /// Substituting rather than adding a parallel ID is what keeps a transport retry idempotent: the
    /// provider re-presents its own ID, this maps it back to the same wake, and the store returns the
    /// already-reserved claim instead of rendering a second one.
    func agentSessionLinkPromptClaim(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> AgentSessionLinkOutboundPromptClaim? {
        agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatchID).claim
    }

    /// The same reservation, with the wake's hard refusal still distinguishable.
    ///
    /// Every provider family goes through this rather than the optional-returning form above, because
    /// the one decision only this can express — "a required lane batch is unavailable, so make no
    /// physical call" — has to be made *before* the transport, and it has to be made identically by
    /// Codex, Claude native, ACP, and headless alike.
    func agentSessionLinkPromptClaimOutcome(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> AgentSessionLinkPromptClaimOutcome {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let context = agentSessionLinkPromptContext(for: session) else {
            // No prompt context at all still refuses a wake: the batch it exists to deliver cannot be
            // rendered, so the turn has nothing to say. Classified by reserved family, exactly as the
            // claim store does, so a malformed Auto-wake identity cannot report the benign
            // "nothing owed" outcome and be dispatched as an ordinary turn.
            return effectiveID.isAutoWakeFamily ? .requiredLaneBatchUnavailable : .nothingOwed
        }
        // Snapshot only this exact observer incarnation's current UI projection. The generation-
        // qualified join remains transient local-display input: it does not enter prompt context,
        // rendering, receipts, or any lookup after this claim is constructed.
        var locationLabelsByReference: [DomainAgentSessionLinkReference: String] = [:]
        if let props = monitorPillPropsByEndpoint[context.epoch.endpoint],
           props.endpoint == context.epoch.endpoint
        {
            for row in props.outbound {
                guard let locationLabel = row.locationLabel,
                      AgentLaneUpdateDisplayAttribution.sanitizedLabel(locationLabel) != nil
                else {
                    continue
                }
                let reference = DomainAgentSessionLinkReference(
                    linkID: row.linkID,
                    generation: row.generation
                )
                guard locationLabelsByReference[reference] == nil else { continue }
                locationLabelsByReference[reference] = locationLabel
            }
        }
        return agentSessionLinkPromptClaimStore.claimOutcome(
            dispatchID: effectiveID,
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            locationLabelsByReference: locationLabelsByReference,
            render: AgentSessionLinkPrompts.rendered
        )
    }

    /// Whether managed-auth recovery may reattach an accepted claim to this exact dispatch.
    ///
    /// A missing prompt context is a hard refusal: withholding is authority, not "nothing currently
    /// owed." Non-empty contexts have already passed the exact current-catalog-route fence.
    func agentSessionLinkCanReuseAcceptedPromptClaim(
        _ claim: AgentSessionLinkOutboundPromptClaim,
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> Bool {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let context = agentSessionLinkPromptContext(for: session) else { return false }
        return agentSessionLinkPromptClaimStore.canReuseAcceptedClaim(
            claim,
            dispatchID: effectiveID,
            epoch: context.epoch,
            inventory: context.inventory
        )
    }

    /// Rewrites an ordinary provider dispatch ID to the in-flight wake's, and nothing else.
    ///
    /// Only a wake that has passed the ownership boundary substitutes: before that it has not started
    /// a run, so any claim being taken belongs to some other dispatch and must keep its own identity.
    ///
    /// "Ordinary" is tested as *not in the reserved Auto-wake family*, not as "carries no wake ID".
    /// A malformed reserved-family value is left exactly as it is: rewriting it would hand the
    /// current wake's identity to a dispatch that never legitimately held one, and the physical fence
    /// refuses it on its own.
    func agentSessionLinkEffectiveDispatchID(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> AgentSessionLinkPromptDispatchID {
        guard !dispatchID.isAutoWakeFamily,
              let attempt = session.pendingOversightAutoWake,
              attempt.phase == .preparingDispatch
              || attempt.phase == .cancelledBeforeDispatch
              || attempt.phase == .dispatching
        else {
            return dispatchID
        }
        return .autoWake(wakeID: attempt.wakeID)
    }

    /// Whether this dispatch would carry a wake's identity, decided without a live view model.
    ///
    /// The same substitution rule as `agentSessionLinkEffectiveDispatchID`, restated only for the
    /// hook closures that must still answer after the view model is gone. Failing closed there is the
    /// point: a teardown mid-dispatch must not be the one path that lets an empty wake turn through.
    ///
    /// The reserved family is what classifies, exactly as it does at the physical fence: a malformed
    /// Auto-wake identity is never ordinary, so it can never take the no-batch-required path.
    static func dispatchRequiresLaneBatch(
        _ session: TabSession,
        _ dispatchID: AgentSessionLinkPromptDispatchID
    ) -> Bool {
        guard !dispatchID.isAutoWakeFamily else { return true }
        guard let phase = session.pendingOversightAutoWake?.phase else { return false }
        return phase == .preparingDispatch
            || phase == .cancelledBeforeDispatch
            || phase == .dispatching
    }

    /// Re-owes the supplement to a session whose **provider context** is being rebuilt from the app
    /// transcript.
    ///
    /// Called from the non-resuming turn path. That path reconstructs the entire conversation from
    /// transcript items, and the supplement is never one of them, so the context about to be sent has
    /// not been taught oversight regardless of what an earlier context acknowledged. Without this the
    /// claim store stays "acknowledged" for the unchanged endpoint and epoch, and no later turn ever
    /// owes the supplement again.
    ///
    /// A no-op for sessions that never held a claim, so it is safe on every rebuild.
    func agentSessionLinkReoweSupplementForRebuiltProviderContext(for session: TabSession) {
        guard let sessionID = session.activeAgentSessionID else { return }
        agentSessionLinkPromptClaimStore.invalidateAcknowledgedContext(observerSessionID: sessionID)
    }

    /// Composes the final provider-bound string for one logical dispatch.
    ///
    /// Returns the (possibly unchanged) text plus the claim the caller must acknowledge at its
    /// provider's acceptance signal. When the dispatch fails or its outcome is unknown, the caller
    /// simply does not acknowledge and the still-current claim stays pending for the retry.
    func agentSessionLinkDecoratedProviderText(
        _ providerText: String,
        session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> AgentSessionLinkDecoratedProviderText {
        let outcome = agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatchID)
        guard let claim = outcome.claim else {
            return AgentSessionLinkDecoratedProviderText(
                text: providerText,
                claim: nil,
                mustAbortDispatch: outcome.mustAbortDispatch
            )
        }
        return AgentSessionLinkDecoratedProviderText(
            text: AgentSessionLinkPromptComposer.decorated(providerText, with: claim),
            claim: claim,
            mustAbortDispatch: false
        )
    }

    /// Acknowledges one accepted dispatch. Idempotent and safe with `nil`.
    ///
    /// The two components settle with their own owners and neither can block the other. Membership
    /// goes to the claim store, which refuses a claim minted in a superseded epoch. The passive
    /// receipt goes to the bridge-owned queue, which is deliberately *not* epoch-token gated: the
    /// provider physically accepted that batch, and the queue's own epoch/revision fencing is what
    /// decides whether it still applies. Gating it on the store's token instead would re-deliver a
    /// batch the model already holds whenever a provider or eligibility flip raced the acceptance.
    ///
    /// Ordering is load-bearing for an accepted auto-wake: the wake's visible provenance row is
    /// recorded *before* the receipt is applied, so the queue republication the receipt triggers
    /// already sees the settled attempt rather than a still-pending one.
    func acceptAgentSessionLinkPromptClaim(_ claim: AgentSessionLinkOutboundPromptClaim?) {
        guard let claim else { return }
        agentSessionLinkPromptClaimStore.accept(claim)
        guard let passive = claim.passive else { return }
        agentSessionLinkRecordAcceptedAutoWake(claim)
        AgentSessionLinkRuntimeBridge.shared.applyPassiveMonitorNoticeReceipt(
            passive.receipt,
            observerEndpoint: passive.observerEndpoint
        )
    }

    /// Releases the claim of a definitively terminal logical dispatch. Idempotent and safe with
    /// `nil`.
    ///
    /// This is *not* an acknowledgement: the supplement stays owed to the next dispatch. Use it only
    /// when the dispatch will never be retried under the same logical ID, so its rendered fragment
    /// is not retained until some unrelated dispatch happens to be accepted.
    ///
    /// A passive batch the claim carried stays queued for exactly the same reason: an abandoned or
    /// ambiguous pre-acceptance outcome acknowledges nothing at all.
    func abandonAgentSessionLinkPromptClaim(_ claim: AgentSessionLinkOutboundPromptClaim?) {
        guard let claim else { return }
        agentSessionLinkPromptClaimStore.abandon(claim)
    }
}
