import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Live-view-model regressions for the cross-session send transaction.
///
/// The reducer, envelope, and bridge suites cover the transaction's *inputs*; this suite covers the
/// ordering and non-consumption guarantees that only exist once a real `AgentModeViewModel`, a real
/// composer claim, and real persistence are in play. Everything here uses a non-Codex agent on
/// purpose: the Codex path reports its own send outcome, while Claude/ACP/headless historically
/// reported success and pre-start failure identically.
@MainActor
final class AgentSessionLinkSendTransactionLiveTests: XCTestCase {
    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let workspaceID: UUID
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let events: LiveSendEventLog
        let driftHook: LiveSendDriftHook
    }

    /// Lets a test land a lifecycle change inside the delivery flush.
    ///
    /// The flush is the transaction's last await before provider dispatch, so it is exactly where a
    /// close, in-place rebind, or workspace switch can slip between the durable commit and the turn
    /// start.
    @MainActor
    final class LiveSendDriftHook {
        var duringDeliveryFlush: (() -> Void)?
    }

    private var retainedViewModels: [AgentModeViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        super.tearDown()
    }

    private func makeFixture(
        saverBehavior: LiveSendEventLog.SaverBehavior = .succeed
    ) throws -> Fixture {
        let events = LiveSendEventLog()
        let driftHook = LiveSendDriftHook()
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Cross-session send",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                // Never exercised: every test here uses a non-Codex agent.
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in
                events.record(.providerControllerCreated)
                return LiveSendStubNativeController()
            },
            // No real MCP policy work: the transaction only needs the runner to reach its provider
            // handoff, and a real installer would do network/process work in the background.
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            let saveIndex = events.recordSave(items: agentSession.toLiveItems())
            // Runs *inside* the delivery flush, which is the only await between the durable commit
            // and provider dispatch. It is where a close, rebind, or workspace switch actually lands.
            if saveIndex == 0 { driftHook.duringDeliveryFlush?() }
            switch saverBehavior {
            case .succeed:
                break
            case .fail:
                throw LiveSendEventLog.SaveFailure()
            case .failFirst:
                if saveIndex == 0 { throw LiveSendEventLog.SaveFailure() }
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }

        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let candidate = try XCTUnwrap(
            viewModel.agentSessionLinkCandidate(
                tabID: tabID,
                sessionID: sessionID,
                tabName: "Build API",
                isWindowClosing: false
            ),
            "expected a live oversight endpoint candidate"
        )

        return Fixture(
            viewModel: viewModel,
            manager: manager,
            workspaceID: workspace.id,
            tabID: tabID,
            sessionID: sessionID,
            session: session,
            candidate: candidate,
            events: events,
            driftHook: driftHook
        )
    }

    /// A synthetic observer incarnation. The observer normally lives in another window, so these
    /// suites never need it to be locally resolvable — only stable and exact.
    private static let observerEndpoint = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2,
        workspaceID: UUID(),
        tabID: UUID(),
        sessionID: UUID(),
        persistentBindingGeneration: UUID(),
        bindingTransitionGeneration: 1
    )

    /// Both endpoints live and the target window open: the ordinary case.
    private static let liveLiveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true,
        targetEndpointIsLive: true,
        targetWindowIsClosing: false
    )

    private func makeRequest(
        message: String = "Please rerun the failing test.",
        workflow: AgentWorkflowDefinition? = nil
    ) -> AgentSessionLinkSendRequest {
        AgentSessionLinkSendRequest(
            linkID: UUID(),
            linkGeneration: 1,
            observerEndpoint: Self.observerEndpoint,
            observerDisplayName: "Planning",
            message: message,
            workflow: workflow
        )
    }

    private func send(
        _ fixture: Fixture,
        request: AgentSessionLinkSendRequest? = nil,
        liveness: @escaping AgentSessionLinkSendLivenessProbe = { liveLiveness },
        commit: @escaping @MainActor () async -> AgentSessionLinkSendCommitOutcome = { .committed }
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await fixture.viewModel.agentSessionLinkPerformSend(
            to: fixture.candidate,
            request: request ?? makeRequest(),
            liveness: liveness,
            commitAuthorization: commit
        )
    }

    // MARK: - Durable acceptance and start reporting

    func testDeliversAttributedRowDurablyBeforeProviderStart() async throws {
        let fixture = try makeFixture()
        let request = makeRequest()

        let outcome = await send(fixture, request: request)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected a delivered outcome, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)

        let userRows = fixture.session.items.filter { $0.kind == .user }
        XCTAssertEqual(userRows.count, 1)
        let row = try XCTUnwrap(userRows.first)
        XCTAssertEqual(row.id, delivery.targetItemID)
        XCTAssertEqual(row.text, request.message, "The row stores the raw message, not the envelope.")
        XCTAssertEqual(row.crossSessionAttribution?.sourceSessionID, request.observerSessionID)
        XCTAssertEqual(row.crossSessionAttribution?.linkID, request.linkID)
        XCTAssertEqual(row.crossSessionAttribution?.sourceName, "Planning")

        // Persistence is the delivery linearization point: the durable payload already contained the
        // attributed row, and it committed before the provider controller was ever created.
        XCTAssertTrue(
            fixture.events.savedItemsContainAttributedRow(id: row.id),
            "The attributed row must be inside the durable payload, not saved afterwards"
        )
        XCTAssertTrue(
            fixture.events.saveHappenedBeforeProviderStart(),
            "Provider start must never precede durable persistence"
        )
    }

    /// Delivery needs no proof about the caller's own turn, and the row it commits is still
    /// structurally attributed to the exact granted observer.
    ///
    /// The user's direct grant is the delegation, so the same request that would once have been
    /// refused as "not started by your own user" now commits — while attribution, which is what stops
    /// an observer from speaking as the target's user, is unchanged.
    func testDeliveryNeedsNoLocalTurnProofAndStaysStructurallyAttributed() async throws {
        let fixture = try makeFixture()
        let request = AgentSessionLinkSendRequest(
            linkID: UUID(),
            linkGeneration: 1,
            observerEndpoint: Self.observerEndpoint,
            observerDisplayName: "Planning",
            message: "ping back",
            workflow: nil
        )

        let outcome = await send(fixture, request: request)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected a durable delivery, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        let row = try XCTUnwrap(fixture.session.items.first { $0.kind == .user })
        XCTAssertEqual(row.text, "ping back")
        XCTAssertEqual(row.crossSessionAttribution?.sourceSessionID, request.observerSessionID)
        XCTAssertEqual(row.crossSessionAttribution?.linkID, request.linkID)
        XCTAssertTrue(fixture.events.savedItemsContainAttributedRow(id: row.id))
    }

    /// Regression for the non-Codex reporting gap: `AgentModeRunService.startRun` returns `nil` for
    /// both success and pre-start failure on Claude/ACP/headless, so an unresolvable execution
    /// workspace used to be reported to the observer as `run_started`.
    func testNonCodexPreProviderStartFailureReportsRunStartFailed() async throws {
        let fixture = try makeFixture()
        fixture.session.worktreeBindings = [
            AgentSessionWorktreeBinding(
                id: UUID().uuidString,
                repositoryID: "repo",
                repoKey: "repo",
                logicalRootPath: FileManager.default.currentDirectoryPath,
                worktreeID: "missing",
                worktreeRootPath: "/var/empty/repoprompt-missing-worktree-\(UUID().uuidString)",
                source: "test"
            )
        ]

        let outcome = await send(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected a delivered outcome, got \(outcome)")
        }
        XCTAssertEqual(
            delivery.deliveryState,
            .runStartFailed,
            "A non-Codex run rejected before provider startup must not be reported as started"
        )
        XCTAssertFalse(
            fixture.events.contains(.providerControllerCreated),
            "No provider should have been created"
        )
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.kind == .user }),
            1,
            "The durably accepted row is preserved after a start failure"
        )
    }

    // MARK: - Non-consumption of next-local-composer state

    func testLeavesWorkflowInterviewAndPendingHandoffUntouched() async throws {
        let fixture = try makeFixture()
        let workflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Review",
            iconName: "checkmark",
            template: "<workflow>{{input}}</workflow>"
        )
        fixture.session.selectedWorkflow = workflow
        fixture.viewModel.selectedWorkflow = workflow
        fixture.viewModel.interviewFirst = true
        fixture.session.pendingHandoff = AgentModeViewModel.PendingHandoffState(
            payload: "<forked_session>prior context</forked_session>",
            createdAt: Date(timeIntervalSince1970: 10),
            sourceItemID: UUID(),
            defersProviderLockUntilSend: true,
            isStagedForSend: false
        )
        let handoffBefore = fixture.session.pendingHandoff

        // A leading slash would be a skill invocation in a local composer send.
        let request = makeRequest(message: "/deploy staging now")
        let outcome = await send(fixture, request: request)

        guard case .delivered = outcome else {
            return XCTFail("Expected a delivered outcome, got \(outcome)")
        }

        XCTAssertEqual(
            fixture.session.selectedWorkflow,
            workflow,
            "A cross-session send must not consume the target's staged Workflow"
        )
        XCTAssertTrue(
            fixture.viewModel.interviewFirst,
            "A cross-session send must not consume the target's Interview toggle"
        )
        XCTAssertEqual(
            fixture.session.pendingHandoff,
            handoffBefore,
            "The staged handoff belongs to the target's next local send: not prepended, not staged, not cleared"
        )
        XCTAssertFalse(fixture.session.pendingHandoff.isStagedForSend)
        XCTAssertTrue(fixture.session.pendingHandoff.defersProviderLockUntilSend)

        let row = try XCTUnwrap(fixture.session.items.first { $0.kind == .user })
        XCTAssertEqual(
            row.text,
            "/deploy staging now",
            "The row is the raw message: no workflow wrapper, no interview block, no slash expansion"
        )
        XCTAssertNil(row.workflow, "A cross-session row must not be badged with the target's workflow")
    }

    /// A per-message workflow is applied to the provider payload and to nothing else.
    ///
    /// The target's composer selection is not saved-and-restored around the send — it is never read
    /// or written at all, which is what makes preservation structural rather than a cleanup step a
    /// failure path could skip.
    func testPerMessageWorkflowWrapsTheEnvelopeWithoutBecomingComposerState() async throws {
        let fixture = try makeFixture()
        let targetOwnWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Target choice",
            iconName: "checkmark",
            template: "TARGET-TEMPLATE $ARGUMENTS"
        )
        fixture.session.selectedWorkflow = targetOwnWorkflow
        fixture.viewModel.selectedWorkflow = targetOwnWorkflow

        let override = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Sender choice",
            iconName: "wand.and.stars",
            template: "OVERRIDE-PREFIX\n$ARGUMENTS\nOVERRIDE-SUFFIX"
        )
        let request = makeRequest(message: "Please rerun the failing test.", workflow: override)

        let outcome = await send(fixture, request: request)

        guard case .delivered = outcome else {
            return XCTFail("Expected a delivered outcome, got \(outcome)")
        }
        XCTAssertEqual(
            fixture.session.selectedWorkflow,
            targetOwnWorkflow,
            "A one-shot workflow must not replace what the target's own user selected"
        )
        XCTAssertEqual(fixture.viewModel.selectedWorkflow, targetOwnWorkflow)

        let row = try XCTUnwrap(fixture.session.items.first { $0.kind == .user })
        XCTAssertEqual(row.text, request.message, "The row still stores the raw message")
        XCTAssertFalse(
            row.text.contains("OVERRIDE-PREFIX"),
            "The workflow belongs to the provider payload, not to the stored transcript text"
        )
        XCTAssertEqual(
            row.workflow,
            override,
            "The attributed row is badged with the workflow this turn actually ran under"
        )
    }

    // MARK: - Races and refusals

    func testLosingTheLocalComposerClaimRefusesWithoutMutating() async throws {
        let fixture = try makeFixture()
        let target = try XCTUnwrap(
            fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.tabID, session: fixture.session)
        )
        let localAttempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: "local user text"
        )
        guard case .claimed = fixture.viewModel.claimComposerSubmitAttempt(
            localAttempt,
            requireActiveTabOwnership: false
        ) else {
            return XCTFail("Expected the local submit to win the claim")
        }

        let outcome = await send(fixture)

        XCTAssertEqual(outcome, .blocked(.targetNotIdle))
        XCTAssertTrue(fixture.session.items.isEmpty, "A lost claim must mutate nothing")
        XCTAssertFalse(fixture.events.contains(.save))
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
    }

    func testPersistenceFailureRollsBackTheStagedRowAndStartsNoRun() async throws {
        // The delivery flush fails and the compensating rollback flush succeeds, so the durable copy
        // provably does not contain the row and the key is safe to retry.
        let fixture = try makeFixture(saverBehavior: .failFirst)

        let outcome = await send(fixture)

        XCTAssertEqual(outcome, .blocked(.persistenceFailed))
        XCTAssertTrue(
            fixture.session.items.isEmpty,
            "A failed durable commit must roll the staged row back out of the transcript"
        )
        XCTAssertFalse(
            fixture.events.contains(.providerControllerCreated),
            "Persistence failure must start no provider turn"
        )
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim must be released")
    }

    /// Regression: an unconfirmable rollback must not report a plain retryable persistence failure.
    ///
    /// The failed delivery flush may already have written the row. If the compensating flush also
    /// fails, the durable state is unknown, and reporting `persistence_failed` would release the
    /// idempotency key for a retry that could produce a second copy of the same logical message.
    func testUnconfirmableRollbackReportsAnIndeterminateOutcomeRatherThanARetryableFailure()
        async throws
    {
        let fixture = try makeFixture(saverBehavior: .fail)

        let outcome = await send(fixture)

        XCTAssertEqual(outcome, .blocked(.persistenceIndeterminate))
        XCTAssertFalse(
            AgentSessionLinkSendFailure.persistenceIndeterminate.isRetryable,
            "An indeterminate durable outcome must never be advertised as retryable"
        )
        XCTAssertTrue(
            AgentSessionLinkSendFailure.persistenceIndeterminate.isDeliveryIndeterminate
        )
        XCTAssertTrue(
            fixture.session.items.isEmpty,
            "The in-memory rollback still runs even when it cannot be durably confirmed"
        )
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }

    func testEndpointDriftAfterTheCommitFenceAbortsBeforeMutating() async throws {
        let fixture = try makeFixture()

        let outcome = await send(fixture) { [manager = fixture.manager, fixture] in
            // Rebind the tab to a different session while the authority commit is in flight.
            _ = manager.compareAndSetActiveAgentSessionID(
                expected: fixture.sessionID,
                replacement: UUID(),
                forTabID: fixture.tabID,
                inWorkspaceID: fixture.workspaceID
            )
            return .committed
        }

        XCTAssertEqual(outcome, .blocked(.endpointInvalidated))
        XCTAssertTrue(fixture.session.items.isEmpty, "A drifted endpoint must never receive the row")
        XCTAssertFalse(fixture.events.contains(.save))
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }

    /// Regression: the delivery flush awaits, so the admitted target must be re-proven after it.
    ///
    /// `startAgentRun(tabID:)` acts on whatever occupies the tab *now*. An in-place rebind during the
    /// flush left the previously admitted facts unchecked, so the observer's turn could be dispatched
    /// against a replacement binding the grant never covered. The row is already durably the
    /// target's, so drift withholds only the provider start.
    func testDriftDuringTheDeliveryFlushRetainsTheRowButStartsNoProvider() async throws {
        let fixture = try makeFixture()
        fixture.driftHook.duringDeliveryFlush = { [manager = fixture.manager, fixture] in
            _ = manager.compareAndSetActiveAgentSessionID(
                expected: fixture.sessionID,
                replacement: UUID(),
                forTabID: fixture.tabID,
                inWorkspaceID: fixture.workspaceID
            )
        }

        let outcome = await send(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected the durable delivery to be retained, got \(outcome)")
        }
        XCTAssertEqual(
            delivery.deliveryState,
            .persisted,
            "A drifted endpoint must never be dispatched to, but the committed row is not rolled back"
        )
        XCTAssertFalse(
            fixture.events.contains(.providerControllerCreated),
            "No provider turn may start against a binding that replaced the admitted one"
        )
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim must be released")
    }

    // MARK: - Host-backed liveness across the committed send

    /// Regression: an observer rebind/close between the commit fence and the transcript append must
    /// not produce a durable row or a provider dispatch.
    ///
    /// The request used to carry only the observer's session UUID and the transaction only ever
    /// revalidated the *target*, so nothing could notice the granted observer incarnation vanishing
    /// across the commit's suspension.
    func testObserverEndpointLossAfterTheCommitFenceDeliversNothing() async throws {
        let fixture = try makeFixture()
        var observerIsLive = true

        let outcome = await send(
            fixture,
            liveness: {
                AgentSessionLinkSendLiveness(
                    observerEndpointIsLive: observerIsLive,
                    targetEndpointIsLive: true,
                    targetWindowIsClosing: false
                )
            },
            commit: {
                // The observer rebinds or closes while the authority commit is in flight.
                observerIsLive = false
                return .committed
            }
        )

        XCTAssertEqual(outcome, .blocked(.endpointInvalidated))
        XCTAssertTrue(fixture.session.items.isEmpty, "no row may exist for a vanished observer")
        XCTAssertFalse(fixture.events.contains(.save))
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }

    /// Regression: the target *window* entering its closing state must block before the append.
    ///
    /// The transaction runs on the target's view model, which cannot see its own window's teardown
    /// flag; it used to assert `isClosing: false` unconditionally.
    func testTargetWindowClosingAfterTheCommitFenceDeliversNothing() async throws {
        let fixture = try makeFixture()
        var windowIsClosing = false

        let outcome = await send(
            fixture,
            liveness: {
                AgentSessionLinkSendLiveness(
                    observerEndpointIsLive: true,
                    targetEndpointIsLive: true,
                    targetWindowIsClosing: windowIsClosing
                )
            },
            commit: {
                windowIsClosing = true
                return .committed
            }
        )

        XCTAssertEqual(outcome, .blocked(.endpointInvalidated))
        XCTAssertTrue(fixture.session.items.isEmpty)
        XCTAssertFalse(fixture.events.contains(.save))
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
    }

    /// A window already closing at admission is refused with no mutation at all.
    func testTargetWindowAlreadyClosingRefusesBeforeTheCommitFence() async throws {
        let fixture = try makeFixture()
        var commitCalls = 0

        let outcome = await send(
            fixture,
            liveness: {
                AgentSessionLinkSendLiveness(
                    observerEndpointIsLive: true,
                    targetEndpointIsLive: true,
                    targetWindowIsClosing: true
                )
            },
            commit: {
                commitCalls += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome, .blocked(.endpointInvalidated))
        XCTAssertEqual(commitCalls, 0, "a closing target window must not even consume the commit fence")
        XCTAssertTrue(fixture.session.items.isEmpty)
        XCTAssertFalse(fixture.events.contains(.save))
    }

    /// Regression: after the persistence await, endpoint/window liveness still gates provider start.
    ///
    /// The row is already durably the target's, so drift retains the delivery and withholds only the
    /// turn — rolling back here would contradict the linearization point.
    func testEndpointLossDuringTheDeliveryFlushRetainsTheRowButStartsNoProvider() async throws {
        let fixture = try makeFixture()
        var observerIsLive = true
        fixture.driftHook.duringDeliveryFlush = { observerIsLive = false }

        let outcome = await send(fixture, liveness: {
            AgentSessionLinkSendLiveness(
                observerEndpointIsLive: observerIsLive,
                targetEndpointIsLive: true,
                targetWindowIsClosing: false
            )
        })

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected the durable delivery to be retained, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .persisted)
        XCTAssertFalse(
            fixture.events.contains(.providerControllerCreated),
            "no provider turn may start once an endpoint of the grant is gone"
        )
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }

    /// The exact granted observer incarnation travels with the request, not just its session UUID.
    func testRequestCarriesTheExactObserverIncarnation() async throws {
        let fixture = try makeFixture()
        let request = makeRequest()

        XCTAssertEqual(request.observerEndpoint, Self.observerEndpoint)
        XCTAssertEqual(
            request.observerSessionID,
            Self.observerEndpoint.sessionID,
            "attribution stays session-scoped while the fences get the full identity"
        )

        let outcome = await send(fixture, request: request)
        guard case .delivered = outcome else { return XCTFail("expected delivery, got \(outcome)") }
        let attributed = try XCTUnwrap(fixture.session.items.first)
        XCTAssertEqual(
            attributed.crossSessionAttribution?.sourceSessionID,
            Self.observerEndpoint.sessionID
        )
    }

    func testRevocationAtTheCommitFenceLeavesTheTargetUntouched() async throws {
        let fixture = try makeFixture()

        let outcome = await send(fixture) { .linkRevoked }

        XCTAssertEqual(outcome, .blocked(.linkRevoked))
        XCTAssertTrue(fixture.session.items.isEmpty)
        XCTAssertFalse(fixture.events.contains(.save))
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt)
    }
}

// MARK: - Event log

/// Ordered record of the two side effects whose relative order is the transaction's contract.
final class LiveSendEventLog: @unchecked Sendable {
    enum Event: Equatable {
        case save
        case providerControllerCreated
    }

    enum SaverBehavior {
        case succeed
        case fail
        /// Fails the delivery flush and then lets the compensating rollback flush succeed.
        case failFirst
    }

    struct SaveFailure: Error {}

    private let lock = NSLock()
    private var events: [Event] = []
    private var saveCount = 0
    private var savedItemIDs: Set<UUID> = []
    private var savedAttributedItemIDs: Set<UUID> = []

    func record(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    /// - Returns: the zero-based index of this save, so a behavior can fail only the first one.
    @discardableResult
    func recordSave(items: [AgentChatItem]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = saveCount
        saveCount += 1
        events.append(.save)
        for item in items {
            savedItemIDs.insert(item.id)
            if item.crossSessionAttribution != nil {
                savedAttributedItemIDs.insert(item.id)
            }
        }
        return index
    }

    func contains(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(event)
    }

    func savedItemsContainAttributedRow(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return savedAttributedItemIDs.contains(id)
    }

    /// True when a save was recorded and no provider was created before it.
    func saveHappenedBeforeProviderStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let saveIndex = events.firstIndex(of: .save) else { return false }
        guard let providerIndex = events.firstIndex(of: .providerControllerCreated) else { return true }
        return saveIndex < providerIndex
    }
}

// MARK: - Provider stubs

/// Minimal native runtime stub. The transaction only needs the Claude runner to reach its provider
/// handoff; nothing here should touch a process, a socket, or the filesystem.
private actor LiveSendStubNativeController: NativeAgentRuntimeControlling {
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
        NativeAgentRuntimeSessionRef(sessionID: "live-send-stub")
    }

    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "live-send-stub")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_: String) async throws -> UUID {
        UUID()
    }

    func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() {}
    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
}
