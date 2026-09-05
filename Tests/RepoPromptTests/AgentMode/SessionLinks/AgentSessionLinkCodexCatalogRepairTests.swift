import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The bounded repair for a Codex observer whose *returned* MCP catalog is stuck saying
/// `agent_session_link` is absent while the link authority still reports a live outbound grant.
///
/// That pair is what `ServerNetworkManager.notifyToolListChangedForAgentSession` republishes when a
/// restored grant activates against a run whose client has not re-read `tools/list`. For an
/// established run `agentSessionLinkPromptContext` then fails closed forever, so Auto-wake is blocked
/// behind a projection nothing in the existing pipeline can heal.
///
/// The ordinary paths are driven black-box, through the same publication hook the server uses: what
/// must be true is that one episode spends at most one controller replacement, that the replacement
/// retires the *process* run while preserving the provider conversation, and that the
/// already-published passive snapshot is re-driven so the cold-bootstrap exception can admit it.
///
/// Three shapes are deliberately unreachable through a projection and therefore call
/// `codexRepairSessionLinkCatalogIfQuiescent` directly — the exact entrypoint
/// `finalizeCodexRun.postCommit` invokes, on the same MainActor frame. The reconciler refuses to
/// re-enter without a live controller (stranded consumed run), refuses once the tool is disabled
/// (delayed disablement), and a queued successor implies an active run that never publishes
/// (fallback ownership). Terminal wiring itself stays covered black-box by
/// `testActiveRunDefersRepairUntilWinningTerminalCommit`.
@MainActor
final class AgentSessionLinkCodexCatalogRepairTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var retainedWorkspaceManagers: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retained.removeAll()
        retainedWorkspaceManagers.removeAll()
        super.tearDown()
    }

    // MARK: - Repair

    /// The whole contract in one pass: an idle Codex observer behind a false/live-outbound catalog
    /// cannot admit a wake, and one exact projection both retires the stale run and re-drives the
    /// unchanged passive snapshot into the cold-bootstrap exception.
    func testExactFalseLiveOutboundProjectionRepairsIdleCodexAndColdBootstrapsSamePassiveSnapshot() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture)
        try publishLane(fixture, queueRevision: 7)
        XCTAssertNil(
            fixture.session.pendingOversightAutoWake,
            "an established run behind a false catalog must not be able to admit a wake"
        )

        let sourceGeneration = fixture.session.codexControllerGeneration
        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)

        XCTAssertNil(fixture.session.runID, "the repair retires the process run identity")
        XCTAssertNil(fixture.session.codexController, "exactly one controller replacement")
        XCTAssertEqual(
            fixture.session.codexConversationID,
            Self.conversationID,
            "provider conversation continuity is preserved across the repair"
        )
        XCTAssertEqual(fixture.session.codexRolloutPath, Self.rolloutPath)
        XCTAssertTrue(fixture.session.codexNeedsReconnect)

        let marker = try XCTUnwrap(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        XCTAssertEqual(marker, sourceGeneration, "the marker records the controller it was opened against")
        XCTAssertNotEqual(
            marker,
            fixture.session.codexControllerGeneration,
            "the replacement's own generation rotation is what consumes the episode"
        )

        let attempt = try XCTUnwrap(
            fixture.session.pendingOversightAutoWake,
            "the cold session must admit the already-published snapshot"
        )
        XCTAssertEqual(attempt.queueRevision, 7, "the same queue revision is re-driven, not a new publication")
    }

    /// A run that is still active never has its provider retired underneath it. The episode is opened
    /// at projection time and spent by the winning terminal commit.
    func testActiveRunDefersRepairUntilWinningTerminalCommit() async throws {
        let fixture = try makeFixture(runService: true)
        beginActiveTurn(fixture)
        let sourceGeneration = fixture.session.codexControllerGeneration

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)

        XCTAssertEqual(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            sourceGeneration,
            "the episode opens while active"
        )
        XCTAssertNotNil(fixture.session.codexController, "no retirement while the run owns the provider")
        XCTAssertNotNil(fixture.session.runID)

        await fixture.viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: Self.turnID, status: .completed),
            session: fixture.session
        )

        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertNil(fixture.session.codexController, "the winning terminal commit spends the episode once")
        XCTAssertNil(fixture.session.runID, "the stale process run is retired")
        XCTAssertEqual(fixture.session.codexConversationID, Self.conversationID)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
        XCTAssertNotEqual(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            fixture.session.codexControllerGeneration
        )
    }

    /// An unrelated reconnect that *succeeded* — it installed a live successor controller — has
    /// already spent the episode's one replacement, and the run it kept is serviceable.
    ///
    /// The sibling case, where that reconnect left no controller at all, is covered by
    /// `testUnrelatedReconnectThatLeftNoControllerRetiresTheStrandedRunAndColdRedrives`.
    func testUnrelatedReconnectWithLiveSuccessorControllerConsumesEpisodeWithoutSecondReplacement() async throws {
        let fixture = try makeFixture(runService: true)
        beginActiveTurn(fixture)
        let sourceGeneration = fixture.session.codexControllerGeneration

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)

        let replacement = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        fixture.session.codexController = replacement
        XCTAssertNotEqual(fixture.session.codexControllerGeneration, sourceGeneration)

        let runIDBeforeTerminal = fixture.session.runID
        await fixture.viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: Self.turnID, status: .completed),
            session: fixture.session
        )

        XCTAssertTrue(
            fixture.session.codexController === replacement,
            "a consumed episode must never perform a second replacement"
        )
        XCTAssertEqual(
            fixture.session.runID,
            runIDBeforeTerminal,
            "a run that still has a provider is not retired"
        )
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
    }

    /// The consumed dead end: a `preserveRunID: true` reconnect retired the controller and its
    /// follow-up start never produced a replacement, so the session holds an established run with no
    /// provider. Nothing will publish a healed catalog for that run, so the repair finishes what the
    /// episode was for — retire the run identity, close the episode, cold-redrive — without a second
    /// controller replacement.
    func testUnrelatedReconnectThatLeftNoControllerRetiresTheStrandedRunAndColdRedrives() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture)
        try publishLane(fixture, queueRevision: 9)
        // Deferred at open so the episode is still pending when the unrelated reconnect lands.
        fixture.session.runState = .running
        let sourceGeneration = fixture.session.codexControllerGeneration

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        // The one field that matters here: `clearCodexControllerInstanceState` nils `codexController`,
        // and with `preserveRunID: true` the run identity survives. The rest of that teardown
        // (permission profile, task-label kind, workspace paths, feature state) is irrelevant to the
        // repair's `controller == nil && runID != nil` test, so it is not reproduced.
        fixture.session.codexController = nil
        XCTAssertNotEqual(fixture.session.codexControllerGeneration, sourceGeneration)
        XCTAssertNotNil(fixture.session.runID)

        // The reconciler cannot re-enter without a controller, so the winning terminal commit is the
        // path that reaches this state. This is the exact call `finalizeCodexRun.postCommit` makes.
        fixture.session.runState = .completed
        fixture.viewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(
            for: fixture.session
        )

        XCTAssertNil(fixture.session.runID, "the stranded established run is retired")
        XCTAssertNil(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            "the episode is over rather than left holding"
        )
        XCTAssertNil(fixture.session.codexController, "no second controller replacement")
        XCTAssertEqual(fixture.session.codexConversationID, Self.conversationID)
        XCTAssertEqual(fixture.session.codexRolloutPath, Self.rolloutPath)
        let attempt = try XCTUnwrap(
            fixture.session.pendingOversightAutoWake,
            "the now-cold session must admit the already-published snapshot"
        )
        XCTAssertEqual(attempt.queueRevision, 9)
    }

    /// A terminal commit that has staged its revision but not finished publishing still owns the run,
    /// so the repair must not pull the provider out from under it. The barrier's own `postCommit`
    /// runs on the safe side of that phase.
    func testTerminalCommitInProgressDefersRepairUntilSafeReconciliation() throws {
        let fixture = try makeFixture()
        fixture.session.runLifecycle.beginTerminalCommit()
        let sourceGeneration = fixture.session.codexControllerGeneration

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)

        XCTAssertEqual(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            sourceGeneration,
            "the episode opens but stays pending"
        )
        XCTAssertNotNil(fixture.session.codexController, "a settling terminal commit still owns the run")
        XCTAssertNotNil(fixture.session.runID)

        fixture.session.runLifecycle.completeTerminalCommit()
        try publishCatalogProjection(fixture, revision: 3, hasAgentSessionLink: false)

        XCTAssertNil(fixture.session.codexController, "the pending episode is spent once it is safe")
        XCTAssertNil(fixture.session.runID)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
    }

    /// Fallback ownership is what makes the terminal call site safe without a `providerSuccessor`
    /// wrapper: an accepted or retryable successor *is* the queue head, and abandoning it would drop
    /// the user's queued text. Once ownership is gone the still-pending episode is spent exactly once.
    func testFallbackOwnershipRefusesTheRepairUntilTheSuccessorQueueIsGone() throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        let sourceGeneration = fixture.session.codexControllerGeneration
        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)

        fixture.session.runState = .completed
        fixture.session.codexFallbackQueue = [
            Self.fallbackQueueEntry(controller: fixture.controller, session: fixture.session)
        ]
        fixture.viewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(
            for: fixture.session
        )
        XCTAssertNotNil(fixture.session.codexController, "a queued successor must not be abandoned")
        XCTAssertNotNil(fixture.session.runID)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)

        fixture.session.codexFallbackQueue = []
        fixture.session.codexFallbackHookGateOwnerBlocker = AgentTabSession.CodexFallbackBlockingTurn(
            threadID: Self.conversationID,
            turnID: Self.turnID,
            controllerInstanceID: ObjectIdentifier(fixture.controller),
            controllerGeneration: sourceGeneration,
            runID: fixture.session.runID,
            runAttemptID: UUID()
        )
        fixture.viewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(
            for: fixture.session
        )
        XCTAssertNotNil(fixture.session.codexController, "a hook-gate owner is fallback ownership too")
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)

        fixture.session.codexFallbackHookGateOwnerBlocker = nil
        fixture.viewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(
            for: fixture.session
        )
        XCTAssertNil(fixture.session.codexController, "released ownership spends the episode once")
        XCTAssertNil(fixture.session.runID)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
    }

    /// Generation comparison — not projection revision or value equality — is the loop bound.
    func testRepeatedHigherRevisionFalseProjectionsNeverReopenOrRepeatTheReplacement() throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        let sourceGeneration = fixture.session.codexControllerGeneration
        let originalController = try XCTUnwrap(fixture.session.codexController)

        for revision in UInt64(2) ... 4 {
            try publishCatalogProjection(fixture, revision: revision, hasAgentSessionLink: false)
        }
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
        XCTAssertTrue(fixture.session.codexController === originalController)

        let replacement = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        fixture.session.codexController = replacement
        try publishCatalogProjection(fixture, revision: 5, hasAgentSessionLink: false)

        XCTAssertTrue(
            fixture.session.codexController === replacement,
            "a higher revision must not re-open a consumed episode"
        )
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
    }

    // MARK: - Episode closure

    /// The three projection/provider exits exercised together here. The other two episode closes —
    /// delayed tool disablement and stranded-run recovery — happen at the repair entrypoint and have
    /// their own tests.
    func testCurrentTrueProjectionOutboundLossAndProviderSwitchCloseTheEpisode() throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertNotNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        try publishCatalogProjection(fixture, revision: 3, hasAgentSessionLink: true)
        XCTAssertNil(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            "an exact current positive catalog closes the episode"
        )

        try publishCatalogProjection(fixture, revision: 4, hasAgentSessionLink: false)
        XCTAssertNotNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        try publishCatalogProjection(
            fixture,
            revision: 5,
            hasAgentSessionLink: false,
            hasActiveOutboundLink: false
        )
        XCTAssertNil(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            "exact outbound loss closes the episode"
        )

        try publishCatalogProjection(fixture, revision: 6, hasAgentSessionLink: false)
        XCTAssertNotNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        fixture.viewModel.test_codexCoordinator.handleProviderSwitch(
            from: .codexExec,
            to: .openCode,
            session: fixture.session
        )
        XCTAssertNil(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            "switching away from Codex closes the episode"
        )
    }

    /// An unknown catalog observation is not evidence that the mismatch healed, so it neither opens
    /// nor closes an episode.
    func testUnknownCatalogPresenceNeitherOpensNorClosesTheEpisode() throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: nil)
        XCTAssertNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)

        try publishCatalogProjection(fixture, revision: 3, hasAgentSessionLink: false)
        let marker = try XCTUnwrap(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)

        try publishCatalogProjection(fixture, revision: 4, hasAgentSessionLink: nil)
        XCTAssertEqual(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            marker,
            "an unknown observation leaves the open episode alone"
        )
    }

    // MARK: - Gates

    /// Disablement is a reason not to repair, never a reason to reconnect: with the tool off the
    /// returned catalog is truthfully absent because the user asked for that.
    func testDisabledSessionLinkToolDoesNotOpenTheEpisode() async throws {
        let store = ToolAvailabilityStore.shared
        try XCTSkipUnless(
            store.isEnabled(MCPWindowToolName.agentSessionLink),
            "this suite asserts the disable transition from the enabled default"
        )
        let fixture = try makeFixture()
        // The store is process-global and persisted, so the enabled state is restored synchronously
        // on every path before this test returns — an asynchronous restore would leak the disabled
        // toggle into whatever runs next.
        await store.toggle(MCPWindowToolName.agentSessionLink, enabled: false)
        var publicationFailure: Error?
        do {
            try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        } catch {
            publicationFailure = error
        }
        await store.toggle(MCPWindowToolName.agentSessionLink, enabled: true)
        if let publicationFailure { throw publicationFailure }

        XCTAssertNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        XCTAssertNotNil(fixture.session.codexController)
        XCTAssertNotNil(fixture.session.runID)
    }

    /// Enablement is re-sampled where the episode is *spent*, not inherited from where it was opened.
    /// A deferred episode can reach a terminal commit long after the user turned the tool off, and
    /// that never justifies a reconnect.
    func testToolDisabledAfterTheEpisodeOpenedClosesItWithoutReconnecting() async throws {
        let store = ToolAvailabilityStore.shared
        try XCTSkipUnless(
            store.isEnabled(MCPWindowToolName.agentSessionLink),
            "this suite asserts the disable transition from the enabled default"
        )
        let fixture = try makeFixture()
        fixture.session.runState = .running
        let sourceGeneration = fixture.session.codexControllerGeneration
        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)

        // Restored synchronously before any assertion can fail out of this test.
        await store.toggle(MCPWindowToolName.agentSessionLink, enabled: false)
        fixture.session.runState = .completed
        fixture.viewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(
            for: fixture.session
        )
        await store.toggle(MCPWindowToolName.agentSessionLink, enabled: true)

        XCTAssertNil(
            fixture.session.codexSessionLinkCatalogRepairSourceGeneration,
            "a disabled tool closes the episode"
        )
        XCTAssertNotNil(fixture.session.codexController, "and never justifies a reconnect")
        XCTAssertNotNil(fixture.session.runID)
    }

    /// An Auto-wake that may already own a physical call must not have its provider retired
    /// underneath it. The pending episode survives and is spent by the next reconciliation.
    func testAutoWakeTransportBoundaryDefersRepairThenSpendsTheEpisodeOnce() throws {
        let fixture = try makeFixture()
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        fixture.session.pendingOversightAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: UUID(),
            observerEndpoint: endpoint,
            queueEpoch: Self.queueEpoch,
            queueRevision: 1,
            wakeFingerprint: Self.laneSnapshot(observerEndpoint: endpoint).wakeEligibilityFingerprint,
            requiredAttentionOccurrence: nil,
            attemptedFingerprint: nil,
            physicalOutcome: .notAttempted,
            phase: .dispatching,
            task: nil
        )
        let sourceGeneration = fixture.session.codexControllerGeneration

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
        XCTAssertNotNil(fixture.session.codexController, "no retirement while a wake owns the transport")
        XCTAssertNotNil(fixture.session.runID)

        fixture.session.pendingOversightAutoWake = nil
        try publishCatalogProjection(fixture, revision: 3, hasAgentSessionLink: false)

        XCTAssertNil(fixture.session.codexController, "the still-pending episode is spent once released")
        XCTAssertNil(fixture.session.runID)
        XCTAssertEqual(fixture.session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
    }

    /// A non-Codex observer is out of scope entirely: this repair is Codex-only by contract.
    func testNonCodexObserverNeverOpensTheEpisode() throws {
        let fixture = try makeFixture()
        fixture.session.selectedAgent = .openCode

        try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)

        XCTAssertNil(fixture.session.codexSessionLinkCatalogRepairSourceGeneration)
        XCTAssertNotNil(fixture.session.codexController)
        XCTAssertNotNil(fixture.session.runID)
    }

    // MARK: - Production diagnostics contract

    #if DEBUG
        func testCatalogDiagnosticsReportOpenAndTerminalSpendWithoutRawIdentifiers() throws {
            let fixture = try makeFixture()
            let runID = try XCTUnwrap(fixture.session.runID)
            AgentSessionLinkCatalogDiagnostics.beginCaptureForTesting()
            do {
                try publishCatalogProjection(fixture, revision: 2, hasAgentSessionLink: false)
            } catch {
                _ = AgentSessionLinkCatalogDiagnostics.endCaptureForTesting()
                throw error
            }
            let records = AgentSessionLinkCatalogDiagnostics.endCaptureForTesting()

            XCTAssertEqual(
                records.map(\.event),
                [.projectionEvaluated, .repairTransition, .repairTransition]
            )
            XCTAssertEqual(
                records.compactMap(\.outcome),
                [.accepted, .opened, .spentReplaced]
            )
            XCTAssertFalse(records.isEmpty)
            let rendered = records.map(\.renderedLine).joined(separator: "\n")
            for rawValue in [
                runID.uuidString,
                fixture.tabID.uuidString,
                fixture.sessionID.uuidString,
                Self.targetID.uuidString,
                Self.conversationID,
                Self.rolloutPath
            ] {
                XCTAssertFalse(rendered.lowercased().contains(rawValue.lowercased()), "raw diagnostic value leaked: \(rawValue)")
            }
        }

        func testCatalogDiagnosticsDistinguishDuplicateStaleAndClose() throws {
            let fixture = try makeFixture()
            fixture.session.runState = .running
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            AgentSessionLinkCatalogDiagnostics.beginCaptureForTesting()
            do {
                let projection = try publishCatalogProjection(
                    fixture,
                    revision: 2,
                    hasAgentSessionLink: false
                )
                fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
                try publishCatalogProjection(fixture, revision: 1, hasAgentSessionLink: false)
                try publishCatalogProjection(fixture, revision: 3, hasAgentSessionLink: true)
            } catch {
                _ = AgentSessionLinkCatalogDiagnostics.endCaptureForTesting()
                throw error
            }
            let outcomes = AgentSessionLinkCatalogDiagnostics.endCaptureForTesting().compactMap(\.outcome)

            XCTAssertEqual(
                outcomes,
                [
                    .accepted,
                    .opened,
                    .coalescedDuplicate,
                    .rejectedStaleRevision,
                    .accepted,
                    .closedCatalogPresent
                ]
            )
        }

        func testCatalogDiagnosticsUseClosedPresenceAndOutcomeVocabulary() {
            let runID = UUID()
            let tabID = UUID()
            let connectionID = UUID()
            AgentSessionLinkCatalogDiagnostics.beginCaptureForTesting()

            AgentSessionLinkCatalogDiagnostics.projectionEvaluated(
                runID: runID,
                tabID: tabID,
                revision: 9,
                catalog: nil,
                outbound: true,
                outcome: .rejectedStaleRevision
            )
            AgentSessionLinkCatalogDiagnostics.toolCallReceived(
                runID: runID,
                tabID: tabID,
                connectionID: connectionID
            )
            let records = AgentSessionLinkCatalogDiagnostics.endCaptureForTesting()

            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records[0].catalog, .unknown)
            XCTAssertEqual(records[0].outbound, .present)
            XCTAssertEqual(records[0].outcome, .rejectedStaleRevision)
            XCTAssertEqual(records[1].event, .toolCallReceived)
            for record in records {
                let rendered = record.renderedLine.lowercased()
                XCTAssertFalse(rendered.contains(runID.uuidString.lowercased()))
                XCTAssertFalse(rendered.contains(tabID.uuidString.lowercased()))
                XCTAssertFalse(rendered.contains(connectionID.uuidString.lowercased()))
            }
        }
    #endif

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let controller: LifecycleNoopCodexController
    }

    private static let conversationID = "codex-catalog-repair-thread"
    private static let rolloutPath = "/tmp/codex-catalog-repair-rollout.jsonl"
    private static let turnID = "turn"
    private static let queueEpoch = UUID(uuidString: "0000000F-0000-0000-0000-000000007701")!

    private func makeFixture(runService: Bool = false) throws -> Fixture {
        let tabID = UUID()
        let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        if runService {
            viewModel.test_initializeRunService()
        }
        retainedWorkspaceManagers.append(
            AgentSessionLinkEndpointTestSupport.installWorkspace(
                on: viewModel,
                tabID: tabID,
                name: "Codex catalog repair"
            )
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.autoWakeOnOversightUpdates = true
        session.installRunID(UUID())
        session.codexConversationID = Self.conversationID
        session.codexRolloutPath = Self.rolloutPath
        session.codexController = controller
        session.codexControllerPermissionProfile = session.permissionProfile
        session.codexControllerWorkspacePaths = .uniform(nil)
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
            memoriesEnabled: CodexMemories.isEnabled
        )
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        return Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            controller: controller
        )
    }

    /// Puts the fixture's session into the shape a live Codex turn has, so the real `turnCompleted`
    /// event reaches `finalizeCodexRun` and its `postCommit`.
    private func beginActiveTurn(_ fixture: Fixture) {
        let session = fixture.session
        session.runState = .running
        session.beginRunAttempt(source: "test.codexCatalogRepair")
        session.codexAuthoritativeActiveTurn = .init(
            threadID: Self.conversationID,
            turnID: Self.turnID,
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(fixture.controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: session.runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = Self.turnID
    }

    @discardableResult
    private func publishCatalogProjection(
        _ fixture: Fixture,
        revision: UInt64,
        hasAgentSessionLink: Bool?,
        hasActiveOutboundLink: Bool? = true
    ) throws -> AgentSessionLinkRunCatalogProjection {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let runID = try XCTUnwrap(fixture.session.runID)
        let projection = AgentSessionLinkRunCatalogProjection(
            runID: runID,
            routeToken: AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            ),
            projectionRevision: revision,
            hasAgentSessionLink: hasAgentSessionLink,
            hasActiveOutboundLink: hasActiveOutboundLink
        )
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
        return projection
    }

    private func publishInventory(_ fixture: Fixture) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        fixture.viewModel.agentSessionLinkPublishPromptInventory(
            AgentSessionLinkPromptInventory(
                observerSessionID: fixture.sessionID,
                linkSetRevision: 1,
                items: [
                    AgentSessionLinkPromptInventoryItem(
                        targetSessionID: Self.targetID,
                        displayName: "Build API",
                        capabilityNames: ["poll", "read", "send_when_idle", "wait"],
                        reference: Self.laneReference
                    )
                ]
            ),
            to: endpoint
        )
    }

    private func publishLane(_ fixture: Fixture, queueRevision: UInt64) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            Self.laneSnapshot(observerEndpoint: endpoint, queueRevision: queueRevision),
            to: endpoint
        )
    }

    // MARK: - Values

    private static let targetID = UUID(uuidString: "00000001-0000-0000-0000-000000007701")!

    private static let laneReference = DomainAgentSessionLinkReference(
        linkID: UUID(uuidString: "0000000F-0000-0000-0000-000000000001")!,
        generation: 1
    )

    private static func fallbackQueueEntry(
        controller: LifecycleNoopCodexController,
        session: AgentModeViewModel.TabSession
    ) -> AgentTabSession.CodexFallbackQueueEntry {
        AgentTabSession.CodexFallbackQueueEntry(
            id: UUID(),
            providerText: "queued follow-up",
            images: [],
            taggedFileAttachments: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            attachmentReservationID: nil,
            optimisticUserItemID: nil,
            draftText: "queued follow-up",
            origin: .manual,
            fallbackReason: .staleAuthoritativeIdentity,
            originThreadID: conversationID,
            originControllerInstanceID: ObjectIdentifier(controller),
            originControllerGeneration: session.codexControllerGeneration,
            originRunID: session.runID ?? UUID(),
            originRunAttemptID: session.activeRunAttemptID ?? UUID(),
            blockingTurn: nil,
            state: .queued
        )
    }

    private static let laneTargetEndpoint = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2,
        workspaceID: UUID(uuidString: "10000001-0000-0000-0000-000000007701")!,
        tabID: UUID(uuidString: "20000001-0000-0000-0000-000000007701")!,
        sessionID: targetID,
        persistentBindingGeneration: UUID(uuidString: "30000001-0000-0000-0000-000000007701")!,
        bindingTransitionGeneration: 1
    )

    private static func laneSnapshot(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        queueRevision: UInt64 = 1
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: queueEpoch,
            queueRevision: queueRevision,
            linkSetRevision: 1,
            isEnabled: true,
            isDeliverable: true,
            entries: [
                AgentSessionLinkPassiveStatusNotices.PendingEntry(
                    reference: laneReference,
                    targetEndpoint: laneTargetEndpoint,
                    targetSessionID: targetID,
                    displayName: "Build API",
                    fromStatus: .running,
                    toStatus: .idle,
                    observedAt: Date(timeIntervalSince1970: 0),
                    idleForSend: true,
                    latestVisibleAssistantPreview: "Done.",
                    changeSequence: 1,
                    edgeSequence: 1
                )
            ],
            attentionRequests: [],
            unacknowledgedOverflowCount: 0,
            overflowProduced: 0,
            autoWakeLanes: [
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: laneReference,
                    targetEndpoint: laneTargetEndpoint,
                    targetSessionID: targetID,
                    isEffectivelySelected: true
                )
            ]
        )
    }
}
