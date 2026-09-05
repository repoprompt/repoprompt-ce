import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The delegated multi-stage pipeline, end to end, with no local user turn anywhere inside it.
///
/// Every other oversight suite proves one seam against synthetic inputs: the readiness reducer
/// against a hand-built snapshot, the coordinator against a hand-published lane snapshot, the live
/// transaction against a hand-built request. Each of those was individually satisfied by the retired
/// caller-origin fence too — the fence only became visible when the *second* hop asked for a turn.
/// So this suite composes the real pieces instead: one real bridge over a real authority, three real
/// `AgentModeViewModel` sessions in three windows, real target readiness, real passive reduction,
/// real Auto-wake admission, and real prompt claiming. Only the provider transport is stubbed.
///
/// What it pins is the product ruling itself: the user's two direct grants are the whole delegation,
/// so `completion → wake → send → completion → wake → send → completion → wake` runs to the end
/// without a human utterance, while each hop still needs its own independently created grant and
/// nothing is inherited by being overseen.
@MainActor
final class AgentSessionLinkAutonomousPipelineTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var retainedWorkspaceManagers: [WorkspaceManagerViewModel] = []
    private var runCatalogRevision: UInt64 = 0

    override func tearDown() {
        retained.removeAll()
        retainedWorkspaceManagers.removeAll()
        super.tearDown()
    }

    // MARK: - The pipeline

    /// Wake 1 → send to target 2 → target 2 completes → wake 2 → send to target 3 → target 3
    /// completes → wake 3, under two independently granted directions and no local user acceptance.
    func testAutonomousPipelineRelaysThroughThreeSessionsUnderTwoIndependentDirectGrants() async throws {
        let pipeline = try makePipeline()
        let observer = pipeline.observer
        let observerEndpoint = try endpoint(observer)

        // Two grants the user created separately. Neither implies the other, and neither is inferred
        // from the other's existence.
        let linkToTwo = try await addDirectGrant(pipeline, to: pipeline.targetTwo)
        let linkToThree = try await addDirectGrant(pipeline, to: pipeline.targetThree)
        XCTAssertNotEqual(linkToTwo.linkID, linkToThree.linkID)

        // Being overseen confers nothing: neither target inherits an outbound grant, and target 2
        // cannot reach target 3 merely because the observer can reach both.
        for overseen in [pipeline.targetTwo, pipeline.targetThree] {
            let inherited = await pipeline.authority.links(forObserver: overseen.sessionID)
            XCTAssertTrue(
                inherited.items.isEmpty,
                "\(overseen.displayName) must inherit no outbound authority from being a target"
            )
        }
        let transitive = try await pipeline.bridge.authorizeTarget(
            operation: .monitorSend,
            observerEndpoint: endpoint(pipeline.targetTwo),
            targetSessionID: pipeline.targetThree.sessionID
        )
        XCTAssertEqual(
            transitive.failure,
            .denied,
            "authority is direct and non-transitive; a relay hop may not borrow the observer's grant"
        )

        // The user selects both lanes for Auto-wake. This is the only automation switch in the test.
        XCTAssertTrue(observer.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [pipeline.targetTwo.sessionID, pipeline.targetThree.sessionID],
            for: observerEndpoint
        ))

        // Hop 0 → wake 1: target 2 finishes work the user had already started there.
        try await completeRun(pipeline, on: pipeline.targetTwo)
        let wakeOne = try XCTUnwrap(
            observer.session.pendingOversightAutoWake,
            "a selected target's completion edge must admit the first wake"
        ).wakeID
        try acceptWake(observer, wakeID: wakeOne)

        // Hop 1: the woken observer sends under the *first* grant. No local user turn ran between the
        // acceptance above and this send — the grant is the delegation.
        let messageToTwo = "Rerun the failing integration test and report the diff."
        let deliveryTwo = try await send(
            pipeline,
            to: pipeline.targetTwo,
            message: messageToTwo,
            idempotencyKey: "pipeline-hop-1"
        )
        XCTAssertEqual(deliveryTwo.receipt.deliveryState, .runStarted)
        XCTAssertFalse(deliveryTwo.receipt.duplicate)
        XCTAssertEqual(deliveryTwo.receipt.targetSessionID, pipeline.targetTwo.sessionID)
        try assertAttributed(
            pipeline.targetTwo,
            to: observer,
            underLink: linkToTwo,
            authorizedBy: deliveryTwo.lease,
            message: messageToTwo
        )

        // Hop 1 → wake 2: target 2 completing the work the observer itself asked for is a genuinely
        // new edge, and it admits again. Under the retired fence this is where the pipeline stalled.
        try await completeRun(pipeline, on: pipeline.targetTwo)
        let wakeTwo = try XCTUnwrap(
            observer.session.pendingOversightAutoWake,
            "the observer's own delegated work completing must admit the next wake"
        ).wakeID
        XCTAssertNotEqual(wakeTwo, wakeOne, "each wake is its own occurrence")
        try acceptWake(observer, wakeID: wakeTwo)

        // Hop 2: a different session, reached only because the user granted that direction too.
        let messageToThree = "Review the rerun result before we ship."
        let deliveryThree = try await send(
            pipeline,
            to: pipeline.targetThree,
            message: messageToThree,
            idempotencyKey: "pipeline-hop-2"
        )
        XCTAssertEqual(deliveryThree.receipt.deliveryState, .runStarted)
        XCTAssertEqual(deliveryThree.receipt.targetSessionID, pipeline.targetThree.sessionID)
        XCTAssertNotEqual(
            deliveryThree.lease.linkID,
            deliveryTwo.lease.linkID,
            "the second hop is authorized by its own grant, not by the first hop's"
        )
        try assertAttributed(
            pipeline.targetThree,
            to: observer,
            underLink: linkToThree,
            authorizedBy: deliveryThree.lease,
            message: messageToThree
        )

        // Hop 2 → wake 3.
        try await completeRun(pipeline, on: pipeline.targetThree)
        let wakeThree = try XCTUnwrap(
            observer.session.pendingOversightAutoWake,
            "the third session's completion must admit the third wake"
        ).wakeID
        XCTAssertEqual(Set([wakeOne, wakeTwo, wakeThree]).count, 3)

        // Nothing in the chain was a local user turn, and nothing in it was refused.
        XCTAssertTrue(
            observer.session.items.allSatisfy { $0.kind != .user },
            "no local user instruction was ever accepted on the observer"
        )
        for wakeID in [wakeOne, wakeTwo] {
            XCTAssertEqual(
                observer.session.items.count(where: { $0.id == wakeID }),
                1,
                "each accepted wake leaves exactly one visible provenance row"
            )
        }
        XCTAssertNil(
            AgentSessionLinkSendFailure(rawValue: "cross_session_reply_requires_user_instruction"),
            "the retired caller-origin refusal must not exist on the wire this pipeline runs over"
        )
    }

    /// Revoking one direction ends that hop and leaves the other one working.
    ///
    /// The companion to the pipeline above: its reach is exactly the set of grants the user currently
    /// holds, never a property the chain acquired by running.
    func testRevokingOneGrantEndsOnlyThatHopOfThePipeline() async throws {
        let pipeline = try makePipeline()
        let observerEndpoint = try endpoint(pipeline.observer)
        let linkToTwo = try await addDirectGrant(pipeline, to: pipeline.targetTwo)
        _ = try await addDirectGrant(pipeline, to: pipeline.targetThree)

        await pipeline.bridge.revokeLink(
            linkID: linkToTwo.linkID,
            generation: linkToTwo.generation
        )

        let revoked = await pipeline.bridge.authorizeTarget(
            operation: .monitorSend,
            observerEndpoint: observerEndpoint,
            targetSessionID: pipeline.targetTwo.sessionID
        )
        XCTAssertEqual(revoked.failure, .denied, "a revoked direction stops authorizing immediately")

        let surviving = try await send(
            pipeline,
            to: pipeline.targetThree,
            message: "Continue with the review.",
            idempotencyKey: "surviving-hop"
        )
        XCTAssertEqual(surviving.receipt.deliveryState, .runStarted)
        XCTAssertTrue(
            pipeline.targetTwo.session.items.allSatisfy { $0.kind != .user },
            "the revoked direction delivered nothing"
        )
    }

    // MARK: - Pipeline steps

    /// Drives one target through a real run/completion cycle and settles the bridge either side.
    ///
    /// Two settles, not one: the reducer coalesces first-to-final within a pass, so
    /// `idle → running → idle` observed in a single reconciliation is a net reversion it correctly
    /// drops. Observing the two transitions separately is what a real target does, and it is what
    /// produces the single `running → idle` completion edge a wake is admitted by.
    private func completeRun(_ pipeline: Pipeline, on node: Node) async throws {
        node.session.runState = .running
        try syncRunCatalogProjection(pipeline.observer)
        await pipeline.bridge.test_settleProjections()
        node.session.runState = .idle
        try syncRunCatalogProjection(pipeline.observer)
        await pipeline.bridge.test_settleProjections()

        let snapshot = try XCTUnwrap(
            pipeline.observer.viewModel
                .agentSessionLinkPassiveNoticesBySessionID[pipeline.observer.sessionID],
            "the observer must hold the queue the bridge just published"
        )
        let edge = try XCTUnwrap(
            snapshot.entries.first { $0.targetSessionID == node.sessionID },
            "\(node.displayName) completing must queue an edge for its own lane"
        )
        XCTAssertEqual(edge.fromStatus, .running)
        XCTAssertEqual(edge.toStatus, .idle)
        XCTAssertTrue(edge.idleForSend, "a completed target is ready to accept the next instruction")
    }

    /// Accepts one wake exactly as a provider's acceptance signal does, through its own claim.
    ///
    /// The coordinator has usually reserved this very claim already — it renders the lane batch
    /// before it starts the wake's turn — so this returns that reservation rather than a second one,
    /// which is exactly how a provider retry stays idempotent.
    private func acceptWake(_ node: Node, wakeID: UUID) throws {
        try syncRunCatalogProjection(node)
        let claim = try XCTUnwrap(
            node.viewModel.agentSessionLinkPromptClaim(
                for: node.session,
                dispatchID: .autoWake(wakeID: wakeID)
            ),
            "a wake must be claimable with the lane batch it exists to deliver"
        )
        var preparing = try XCTUnwrap(node.session.pendingOversightAutoWake)
        XCTAssertEqual(preparing.wakeID, wakeID)
        preparing.task?.cancel()
        preparing.task = nil
        preparing.phase = .preparingDispatch
        node.session.pendingOversightAutoWake = preparing
        XCTAssertTrue(
            node.viewModel.agentSessionLinkAcquirePhysicalDispatch(
                for: node.session,
                dispatchID: claim.dispatchID
            ),
            "the idle follow-up must cross the shared immutable-claim acquisition fence"
        )
        node.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertNil(node.session.pendingOversightAutoWake, "an accepted wake settles")
    }

    private struct Delivery {
        let receipt: DomainAgentSessionLinkSendReceipt
        let lease: DomainAgentSessionLinkLease
    }

    /// One real bridge send: authorize the exact grant, then run the target's own transaction.
    private func send(
        _ pipeline: Pipeline,
        to node: Node,
        message: String,
        idempotencyKey: String
    ) async throws -> Delivery {
        let observerEndpoint = try endpoint(pipeline.observer)
        let authorization = await pipeline.bridge.authorizeTarget(
            operation: .monitorSend,
            observerEndpoint: observerEndpoint,
            targetSessionID: node.sessionID
        )
        let authorized = try XCTUnwrap(
            authorization.success,
            "the user's direct grant must authorize this hop"
        )
        let outcome = await pipeline.bridge.send(
            target: authorized,
            message: message,
            idempotencyKey: idempotencyKey,
            workflowReference: nil
        )
        guard case let .receipt(receipt) = outcome else {
            XCTFail("A grant-authorized send into an idle target must deliver: \(outcome)")
            throw PipelineFailure.notDelivered(String(describing: outcome))
        }
        return Delivery(receipt: receipt, lease: authorized.lease)
    }

    /// Every delivered row names the exact granted observer incarnation and the exact link.
    private func assertAttributed(
        _ node: Node,
        to observer: Node,
        underLink link: DomainAgentSessionLinkReference,
        authorizedBy lease: DomainAgentSessionLinkLease,
        message: String
    ) throws {
        let row = try XCTUnwrap(
            node.session.items.last { $0.kind == .user },
            "\(node.displayName) must hold the delivered row"
        )
        XCTAssertEqual(row.text, message, "the row stores the raw message, not the envelope")
        let attribution = try XCTUnwrap(
            row.crossSessionAttribution,
            "a cross-session delivery is never anonymous"
        )
        XCTAssertEqual(attribution.sourceSessionID, observer.sessionID)
        XCTAssertEqual(attribution.sourceName, observer.displayName)
        XCTAssertEqual(attribution.linkID, link.linkID)
        XCTAssertEqual(lease.linkID, link.linkID)
        XCTAssertEqual(
            lease.linkGeneration,
            link.generation,
            "the delivery ran against the live generation of that exact grant"
        )
        XCTAssertEqual(lease.observer.sessionID, observer.sessionID)
        XCTAssertEqual(lease.target.sessionID, node.sessionID)
    }

    // MARK: - Composition

    private enum PipelineFailure: Error {
        case notDelivered(String)
        case notGranted(String)
    }

    private struct Node {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let windowID: Int
        let displayName: String
    }

    private struct Pipeline {
        let authority: DomainAgentSessionLinkAuthority
        /// Retained here because the bridge holds its host **weakly**. Dropping it would not fail
        /// loudly: every endpoint-scoped call would simply start answering "no candidates", and the
        /// pipeline would read as a product regression instead of a dead fixture reference.
        let host: LiveWindowEndpointHost
        let bridge: AgentSessionLinkRuntimeBridge
        let observer: Node
        let targetTwo: Node
        let targetThree: Node
    }

    private func makePipeline() throws -> Pipeline {
        let observer = try makeNode(windowID: 1, displayName: "Planning")
        let targetTwo = try makeNode(windowID: 2, displayName: "Build API")
        let targetThree = try makeNode(windowID: 3, displayName: "Review API")

        let host = LiveWindowEndpointHost()
        for node in [observer, targetTwo, targetThree] {
            host.register(node.viewModel, windowID: node.windowID)
        }
        let authority = DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { _ in },
            now: { Date(timeIntervalSince1970: 1000) }
        )

        // The observer is mid-turn for the whole pipeline, which is what a delegated PM session
        // actually is: each target's completion lands while it is still working its user's standing
        // instruction, and each `send` below is a tool call inside that turn. It is also what keeps
        // the wake path decidable here — a busy observer has no dispatch route, so the coordinator
        // parks each admitted wake in `.awaitingSettlement` and the test supplies the provider's own
        // claim/acceptance step explicitly instead of racing a stubbed provider's run.
        observer.session.runState = .running

        // The one input the bridge does not own: the observer's run-catalog route, published by the
        // run catalog in production. Without it the observer has no supplement-eligible prompt
        // context, so no wake could be reserved for reasons that have nothing to do with this test.
        try syncRunCatalogProjection(observer)

        return Pipeline(
            authority: authority,
            host: host,
            bridge: bridge,
            observer: observer,
            targetTwo: targetTwo,
            targetThree: targetThree
        )
    }

    private func makeNode(windowID: Int, displayName: String) throws -> Node {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                // Never exercised: every session here is a non-Codex agent.
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in AutonomousPipelineStubNativeController() },
            // No real MCP policy work: a delivered send only has to reach its provider handoff, and a
            // real installer would do process and network work in the background.
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "\(displayName) workspace",
            tabName: displayName
        )
        retainedWorkspaceManagers.append(workspaceManager)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }

        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        return Node(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            windowID: windowID,
            displayName: displayName
        )
    }

    /// Publishes the observer's run-catalog route for whatever run it is on *now*, and nothing when
    /// that route is already current.
    ///
    /// Stands in for the run catalog, which publishes one projection per run. Re-driven rather than
    /// published once because the run ID is the thing it is keyed to: any path that rotates the
    /// observer's run would otherwise strand the projection on a dead ID, and every later claim would
    /// then fail for a reason that has nothing to do with what these tests assert.
    private func syncRunCatalogProjection(_ node: Node) throws {
        let endpoint = try endpoint(node)
        let runID = try XCTUnwrap(node.session.runID)
        guard node.viewModel
            .agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]?.runID != runID
        else {
            return
        }
        runCatalogRevision += 1
        let routeToken = AgentSessionLinkRunCatalogRouteToken(
            runID: runID,
            observerEndpoint: endpoint,
            connectionID: UUID(),
            routingAuthorityGeneration: 1,
            connectionLifecycleGeneration: 1
        )
        #if DEBUG
            if node.session.selectedAgent.usesClaudeNativeRuntime {
                node.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                    requestedRunID,
                    requestedWindowID,
                    requestedTabID in
                    guard requestedRunID == routeToken.runID,
                          requestedWindowID == routeToken.observerEndpoint.windowID,
                          requestedTabID == routeToken.observerEndpoint.tabID
                    else { return nil }
                    return routeToken
                }
                node.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, requestedTabID in
                    candidate == routeToken && requestedTabID == routeToken.observerEndpoint.tabID
                }
            }
        #endif
        node.viewModel.agentSessionLinkPublishRunCatalogProjection(
            AgentSessionLinkRunCatalogProjection(
                runID: runID,
                routeToken: routeToken,
                projectionRevision: runCatalogRevision,
                hasAgentSessionLink: true
            ),
            to: endpoint
        )
    }

    private func endpoint(_ node: Node) throws -> DomainAgentSessionLinkEndpointIdentity {
        try AgentSessionLinkEndpointTestSupport.endpoint(node.viewModel, tabID: node.tabID)
    }

    /// One direct grant, created through the same Add path the Oversee control uses.
    private func addDirectGrant(
        _ pipeline: Pipeline,
        to node: Node
    ) async throws -> DomainAgentSessionLinkReference {
        let outcome = await pipeline.bridge.addMonitorLink(
            observerSessionID: pipeline.observer.sessionID,
            rawTargetSessionID: node.sessionID.uuidString
        )
        guard case .added = outcome else {
            XCTFail("The user's Add must create a direct grant: \(outcome)")
            throw PipelineFailure.notGranted(String(describing: outcome))
        }
        let inventory = await pipeline.authority.links(forObserver: pipeline.observer.sessionID)
        let item = try XCTUnwrap(
            inventory.items.first { $0.targetSessionID == node.sessionID },
            "the new grant must appear in the observer's own inventory"
        )
        return DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
    }
}

// MARK: - Live cross-window host

/// A cross-window endpoint host backed by real view models.
///
/// Production's host is `WindowStatesManager`; this mirrors its routing rule for rule — one view
/// model per window ID, every endpoint-scoped call addressed by the full incarnation rather than by
/// session UUID — so the bridge under test runs its real candidate resolution, projection, passive
/// reduction, liveness, and send paths. Nothing here answers *for* a target: `performSend` reaches
/// the target view model's own transaction, and readiness is whatever that session really is.
@MainActor
private final class LiveWindowEndpointHost: AgentSessionLinkEndpointHost {
    private var viewModelsByWindowID: [Int: AgentModeViewModel] = [:]

    func register(_ viewModel: AgentModeViewModel, windowID: Int) {
        viewModelsByWindowID[windowID] = viewModel
    }

    func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
        viewModelsByWindowID.keys.sorted().flatMap { windowID in
            viewModelsByWindowID[windowID]?.agentSessionLinkCandidates(isWindowClosing: false) ?? []
        }
    }

    func agentSessionLinkObservationSnapshot(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot {
        guard let viewModel = viewModelsByWindowID[candidate.windowID] else {
            return DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1000)
            )
        }
        return viewModel.agentSessionLinkObservationSnapshot(for: candidate)
    }

    func agentSessionLinkStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkStatusProjection? {
        viewModelsByWindowID[candidate.windowID]?.agentSessionLinkStatusProjection(for: candidate)
    }

    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        viewModelsByWindowID[candidate.windowID]?
            .agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate) ?? false
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        viewModelsByWindowID[candidate.windowID]?
            .agentSessionLinkAutoWakeTargetSessionIDs(for: candidate) ?? []
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _ enabled: Bool,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        owningViewModel(for: endpoint)?
            .agentSessionLinkSetAutoWakeOnUpdatesEnabled(enabled, for: endpoint) ?? false
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _ targetSessionIDs: Set<UUID>,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        owningViewModel(for: endpoint)?
            .agentSessionLinkSetAutoWakeTargetSessionIDs(targetSessionIDs, for: endpoint) ?? false
    }

    @discardableResult
    func agentSessionLinkSetWaitingOn(
        _ waitingOn: DomainAgentSessionWaitingOn?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        owningViewModel(for: endpoint)?
            .agentSessionLinkSetWaitingOn(waitingOn, for: endpoint) ?? false
    }

    func agentSessionLinkAutoWakeSnoozeProjection(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = owningViewModel(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        return viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        )
    }

    func agentSessionLinkMutateAutoWakeSnooze(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = owningViewModel(for: endpoint) else {
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
        viewModelsByWindowID[candidate.windowID]?
            .agentSessionLinkInstallObservation(for: candidate, onChange: onChange)
    }

    func agentSessionLinkPublishProjection(
        _ props: AgentMonitorPillProps,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        owningViewModel(for: endpoint)?.agentSessionLinkPublishProjection(props, to: endpoint)
    }

    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        owningViewModel(for: endpoint)?
            .agentSessionLinkPublishPromptInventory(inventory, to: endpoint)
    }

    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        owningViewModel(for: endpoint)?
            .agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64? {
        owningViewModel(for: endpoint)?.agentSessionLinkWithholdPromptInventory(for: endpoint)
    }

    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        owningViewModel(for: endpoint)?.agentSessionLinkReleasePromptInventoryHold(
            token,
            for: endpoint,
            publishing: inventory
        )
    }

    func agentSessionLinkTranscriptPage(
        for candidate: AgentSessionLinkEndpointCandidate,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID?
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        guard let viewModel = viewModelsByWindowID[candidate.windowID] else {
            return .failure(.endpointInvalidated)
        }
        return await viewModel.agentSessionLinkTranscriptPage(
            for: candidate,
            anchor: anchor,
            direction: direction,
            maxItems: maxItems,
            maxOutputBytes: maxOutputBytes,
            readerSessionID: readerSessionID
        )
    }

    func agentSessionLinkSendLiveness(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkSendLiveness {
        let live = agentSessionLinkCandidates()
        return AgentSessionLinkSendLiveness(
            observerEndpointIsLive: live.contains { $0.domainEndpoint == observer },
            targetEndpointIsLive: live.contains { $0.domainEndpoint == target },
            targetWindowIsClosing: viewModelsByWindowID[target.windowID] == nil
        )
    }

    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard let viewModel = viewModelsByWindowID[candidate.windowID] else {
            return .blocked(.endpointInvalidated)
        }
        return await viewModel.agentSessionLinkPerformSend(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    /// The view model that currently owns this exact endpoint incarnation, or `nil`.
    ///
    /// Full incarnation match, exactly as production does: an in-place rebind keeps the tab and
    /// session UUIDs while advancing the binding generations, so a UUID-keyed lookup would hand a
    /// superseded incarnation the granted one's publications.
    private func owningViewModel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentModeViewModel? {
        guard let viewModel = viewModelsByWindowID[endpoint.windowID],
              viewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else {
            return nil
        }
        return viewModel
    }
}

// MARK: - Provider stub

/// Minimal native runtime stub: the pipeline only needs a delivered send to reach its provider
/// handoff, so nothing here touches a process, a socket, or the filesystem.
private actor AutonomousPipelineStubNativeController: NativeAgentRuntimeControlling {
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init() {
        stream = AsyncStream { $0.finish() }
    }

    var hasActiveSession: Bool {
        false
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}

    func startOrResume(
        existingSessionID _: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "autonomous-pipeline-stub")
    }

    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "autonomous-pipeline-stub")
    }

    func applyModelAndEffort(
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?
    ) async throws {}

    func sendUserMessage(_: String) async throws -> UUID {
        UUID()
    }

    func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() {}
    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }

    var success: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
