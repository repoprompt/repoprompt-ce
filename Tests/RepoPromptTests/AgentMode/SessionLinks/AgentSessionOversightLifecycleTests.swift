import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Quit-only lifetime, the durable deletion fence, and the bounded termination freeze.
///
/// These are the paths where a mistake is invisible until the next launch: a saved relationship
/// silently deleted by the window-close cascade that quitting produces, or a deleted transcript
/// still reachable through a grant because the tab had not torn down yet.
@MainActor
final class AgentSessionOversightLifecycleTests: XCTestCase {
    // MARK: - Fake host

    private final class FakeHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            candidates
        }

        func agentSessionLinkObservationSnapshot(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> DomainAgentSessionObservationSnapshot {
            DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                idleForSend: true,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 100)
            )
        }

        func agentSessionLinkStatusProjection(
            for _: AgentSessionLinkEndpointCandidate
        ) -> AgentSessionLinkStatusProjection? {
            AgentSessionLinkStatusProjection(status: .idle, pendingInteractionKind: nil)
        }

        func agentSessionLinkInstallObservation(
            for _: AgentSessionLinkEndpointCandidate,
            onChange _: @escaping @MainActor () -> Void
        ) -> AgentSessionLinkObservationToken? {
            AgentSessionLinkObservationToken {}
        }

        func agentSessionLinkPublishProjection(
            _: AgentMonitorPillProps,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkPublishPromptInventory(
            _: AgentSessionLinkPromptInventory,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkPublishPassiveStatusNotices(
            _: AgentSessionLinkPassiveStatusNotices.Snapshot,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkWithholdPromptInventory(
            for _: DomainAgentSessionLinkEndpointIdentity
        ) -> UInt64? {
            nil
        }

        func agentSessionLinkReleasePromptInventoryHold(
            _: UInt64?,
            for _: DomainAgentSessionLinkEndpointIdentity,
            publishing _: AgentSessionLinkPromptInventory?
        ) {}

        func agentSessionLinkTranscriptPage(
            for _: AgentSessionLinkEndpointCandidate,
            anchor _: AgentSessionLinkTranscriptAnchor?,
            direction _: AgentSessionLinkReadDirectionInput,
            maxItems _: Int,
            maxOutputBytes _: Int,
            readerSessionID _: UUID?
        ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
            .failure(.endpointInvalidated)
        }

        func agentSessionLinkSendLiveness(
            observer _: DomainAgentSessionLinkEndpointIdentity,
            target _: DomainAgentSessionLinkEndpointIdentity
        ) -> AgentSessionLinkSendLiveness {
            .unavailable
        }

        func agentSessionLinkPerformSend(
            to _: AgentSessionLinkEndpointCandidate,
            request _: AgentSessionLinkSendRequest,
            liveness _: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            .blocked(.shuttingDown)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let bridge: AgentSessionLinkRuntimeBridge
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeHost
        let store: AgentSessionOversightIntentStore
        let observer: AgentSessionLinkEndpointCandidate
        let target: AgentSessionLinkEndpointCandidate

        var pair: AgentSessionOversightIntent {
            AgentSessionOversightIntent(
                observerSessionID: observer.sessionID,
                targetSessionID: target.sessionID
            )
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oversight-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AgentSessionDeletionRegistry.shared.test_reset()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        AgentSessionDeletionRegistry.shared.test_reset()
        try super.tearDownWithError()
    }

    private func makeCandidate(windowID: Int, displayName: String) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: displayName,
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main"
        )
    }

    private func makeFixture() -> Fixture {
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
        let host = FakeHost()
        let observer = makeCandidate(windowID: 1, displayName: "Planning")
        let target = makeCandidate(windowID: 2, displayName: "Build API")
        host.candidates = [observer, target]
        let store = AgentSessionOversightIntentStore(
            fileURL: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
            mode: .enabled
        )
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { _ in }
        )
        bridge.installIntentStore(store)
        return Fixture(
            bridge: bridge,
            authority: authority,
            host: host,
            store: store,
            observer: observer,
            target: target
        )
    }

    private func add(_ fixture: Fixture) async -> AgentMonitorAddOutcome {
        await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
    }

    // MARK: - Revocation policy

    /// Exhaustive over the domain enum: a newly added reason must be classified deliberately, not
    /// inherit whichever branch a `default` happened to fall into.
    func testEveryRevocationReasonHasAnExplicitDurableIntentPolicy() {
        let preserving: Set<DomainAgentSessionLinkRevocationReason> = [.runtimeShutdown, .appTerminating]
        for reason in DomainAgentSessionLinkRevocationReason.allCases {
            let expected: AgentSessionLinkRuntimeBridge.DurableIntentPolicy =
                preserving.contains(reason) ? .preserveIntent : .removeIntent
            XCTAssertEqual(
                AgentSessionLinkRuntimeBridge.durableIntentPolicy(for: reason),
                expected,
                "Unclassified revocation reason: \(reason.rawValue)"
            )
        }
    }

    func testAnOrdinaryLifecycleRevocationRemovesTheSavedRelationship() async {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let beforeClose = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(beforeClose)

        await fixture.bridge.invalidateWindow(1, reason: .windowClosed)

        let afterClose = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(afterClose, "v1 creates no invisible dormant subscriptions across window closes.")
    }

    func testShutdownRevocationPreservesTheSavedRelationship() async {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }

        await fixture.bridge.invalidateWindow(1, reason: .appTerminating)

        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(token, "Quitting must preserve the relationship for the next launch.")
    }

    /// External MCP control attaches: the endpoint identity is unchanged, so neither the stale
    /// endpoint sweep nor identity revalidation would ever notice. Only the eligibility audit does.
    func testAnObserverThatLosesTheCapabilityIsRevokedWithoutAnyBindingChange() async {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }

        let captured = AgentSessionLinkEndpointCandidate(
            windowID: fixture.observer.windowID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            sessionID: fixture.observer.sessionID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: true,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: fixture.observer.displayName,
            providerDisplayName: fixture.observer.providerDisplayName,
            locationLabel: fixture.observer.locationLabel
        )
        XCTAssertEqual(
            captured.domainEndpoint,
            fixture.observer.domainEndpoint,
            "The identity must be unchanged, or this would be an ordinary drift revocation."
        )
        fixture.host.candidates = [captured, fixture.target]

        await fixture.bridge.test_auditObserverEligibility()

        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(token, "Permanent eligibility loss ends the saved relationship too.")
    }

    // MARK: - Deletion fence

    func testDeletionReporterPhasesPreserveIntentOnFailureAndTombstoneOnCommit() async {
        let registry = AgentSessionDeletionRegistry.shared
        let sessionID = UUID()

        let failing = registry.beginDurableDeletion(sessionID: sessionID)
        XCTAssertTrue(registry.isDeletionInProgress(sessionID: sessionID))
        XCTAssertTrue(registry.blocksNewOversight(sessionID: sessionID))
        XCTAssertFalse(registry.isPermanentlyDeleted(sessionID: sessionID))

        registry.didFailDurableDeletion(failing)
        XCTAssertFalse(registry.blocksNewOversight(sessionID: sessionID), "A failed attempt deleted nothing.")

        let committing = registry.beginDurableDeletion(sessionID: sessionID)
        await registry.didCommitDurableDeletion(committing)
        XCTAssertEqual(registry.state(forSessionID: sessionID), .committed)

        // A stale failure report from a superseded attempt must not reopen a committed tombstone,
        // and a later begin must not downgrade it either.
        registry.didFailDurableDeletion(failing)
        _ = registry.beginDurableDeletion(sessionID: sessionID)
        XCTAssertEqual(registry.state(forSessionID: sessionID), .committed)
        XCTAssertFalse(registry.isDeletionInProgress(sessionID: sessionID))
    }

    func testOverlappingDeletionFailureKeepsTheRemainingAttemptTransientlyBlocked() {
        let registry = AgentSessionDeletionRegistry.shared
        let sessionID = UUID()
        let first = registry.beginDurableDeletion(sessionID: sessionID)
        let second = registry.beginDurableDeletion(sessionID: sessionID)

        registry.didFailDurableDeletion(second)

        XCTAssertTrue(registry.isDeletionInProgress(sessionID: sessionID))
        XCTAssertTrue(registry.blocksNewOversight(sessionID: sessionID))
        XCTAssertFalse(registry.isPermanentlyDeleted(sessionID: sessionID))

        registry.didFailDurableDeletion(first)
        XCTAssertFalse(registry.blocksNewOversight(sessionID: sessionID))
    }

    func testAddIsRefusedWhileTheTargetsDeletionIsInProgress() async {
        let fixture = makeFixture()
        _ = AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: fixture.target.sessionID)

        let outcome = await add(fixture)

        XCTAssertEqual(outcome, .failed(.closing))
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(token, "Nothing may be persisted for a session whose transcript is being removed.")
    }

    func testInProgressDeletionDeniesOperationsWithoutRetiringIntentAndFailureRestoresAccess() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let storedBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedBefore)
        let attempt = AgentSessionDeletionRegistry.shared
            .beginDurableDeletion(sessionID: fixture.target.sessionID)

        let denied = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )

        if case .success = denied { XCTFail("An operation must be denied while deletion is in progress.") }
        let during = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertEqual(during.items.count, 1, "A reversible attempt must not revoke the grant.")
        let tokenDuring = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(tokenDuring, tokenBefore)

        AgentSessionDeletionRegistry.shared.didFailDurableDeletion(attempt)
        let restored = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        if case .failure = restored { XCTFail("A failed deletion must restore ordinary eligibility.") }
        let tokenAfterFailure = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(tokenAfterFailure, tokenBefore)
    }

    func testDeletionCommitAfterActivationCannotReportOrLeaveAEstablishedGrant() async {
        let fixture = makeFixture()
        fixture.bridge.attach(host: fixture.host)
        let fence = TestReleaseFence(name: "post-activation deletion fence")
        fixture.bridge.test_afterActivationBeforeDeletionFence = { pair in
            guard pair == fixture.pair else { return }
            await fence.enterAndWait()
        }

        let addTask = Task { @MainActor in await add(fixture) }
        await fence.waitUntilEntered()
        let attempt = AgentSessionDeletionRegistry.shared
            .beginDurableDeletion(sessionID: fixture.target.sessionID)
        await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(attempt)
        fence.release()
        let outcome = await addTask.value

        XCTAssertNotNil(outcome.failureMessage, "An establishment fenced by committed deletion cannot report success.")
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
        let tokenAfterCommit = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(tokenAfterCommit)
    }

    func testACommittedDeletionRevokesTheGrantAndRemovesEverySavedRowTouchingIt() async {
        let fixture = makeFixture()
        // The commit observer is installed by `attach`, which also needs a host.
        fixture.bridge.attach(host: fixture.host)
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }

        let attempt = AgentSessionDeletionRegistry.shared
            .beginDurableDeletion(sessionID: fixture.target.sessionID)
        await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(attempt)

        // Asserted with no draining, yielding, or settling of any kind. The commit phase awaits its
        // observer, so by the time it returns the UUID-wide authority invalidation and the durable
        // removal have both finished — which is what lets the deleting caller go on to metadata
        // cleanup, the next batch file, and view-model teardown safely.
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(token)

        // Re-adding must stay refused for the rest of the process: deletion is irreversible.
        let reAdd = await add(fixture)
        XCTAssertEqual(reAdd, .failed(.closing))
    }

    // MARK: - Termination freeze

    func testFreezeRefusesAddBeforeAnythingIsInsertedOrReserved() async {
        let fixture = makeFixture()
        fixture.bridge.freezeForTermination()

        let outcome = await add(fixture)

        XCTAssertEqual(
            outcome.failureMessage,
            AgentSessionOversightPersistenceCopy.shutdownBeforeInsert
        )
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(token)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
    }

    func testFreezeRefusesStopWithoutChangingTheIntentOrTheGrant() async throws {
        let fixture = makeFixture()
        guard case let .added(linkID, _) = await add(fixture) else {
            return XCTFail("Expected the link to be added")
        }
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        let item = try XCTUnwrap(inventory.items.first)
        fixture.bridge.freezeForTermination()

        let outcome = await fixture.bridge.stopMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            targetSessionID: fixture.target.sessionID,
            linkID: linkID,
            generation: item.generation
        )

        XCTAssertEqual(
            outcome,
            .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        )
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(token)
        let after = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertEqual(after.items.count, 1)
    }

    /// The freeze must survive the teardown cascade quitting produces: every window closes, and each
    /// close would otherwise read as an ordinary lifecycle end that deletes the saved relationship.
    func testTeardownAfterFreezeCannotDeleteSavedIntent() async {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        fixture.bridge.freezeForTermination()

        await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)

        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(token, "Termination freeze overrides later teardown callbacks.")
    }

    func testBoundedSettlementReturnsPromptlyWithNoRegisteredTransactions() async {
        let fixture = makeFixture()
        _ = await fixture.store.loadForLaunch()

        await fixture.bridge.settleIntentTransactions(deadlineSeconds: 0.25)

        XCTAssertTrue(fixture.bridge.isFrozenForShutdown)
    }

    /// Occupies the store actor's executor, which is what a hung filesystem looks like from outside.
    private final class BlockingWriter: @unchecked Sendable {
        private let began = DispatchSemaphore(value: 0)
        private let seconds: TimeInterval

        init(seconds: TimeInterval) {
            self.seconds = seconds
        }

        func write(_ data: Data, to url: URL) throws {
            began.signal()
            Thread.sleep(forTimeInterval: seconds)
            try data.write(to: url, options: .atomic)
        }

        /// Resolves once the store actor is genuinely blocked, so the assertion below is about the
        /// deadline rather than about having raced the writer.
        func waitUntilWriting() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { [began] in
                    began.wait()
                    continuation.resume()
                }
            }
        }
    }

    /// The shutdown deadline is *total*, and covers the phases that have no work of their own.
    ///
    /// The serialization barrier is the dangerous one: it registers nothing, so a store operation
    /// nobody registered — a launch cleanup, a deletion cleanup, a bootstrap load, or a writer
    /// already occupying the actor — could hold application termination open indefinitely inside it.
    func testShutdownDeadlineIsTotalWhenAnUnregisteredStoreOperationIsStuck() async {
        let blocker = BlockingWriter(seconds: 1.5)
        let store = AgentSessionOversightIntentStore(
            fileURL: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
            mode: .enabled,
            writer: { data, url in try blocker.write(data, to: url) }
        )
        let fixture = makeFixture()
        fixture.bridge.installIntentStore(store)
        _ = await store.loadForLaunch()
        // Deliberately unregistered: this is not a user-facing Add or Stop transaction.
        let occupier = Task {
            await store.insert(
                AgentSessionOversightIntent(observerSessionID: UUID(), targetSessionID: UUID())
            )
        }
        await blocker.waitUntilWriting()

        let started = Date()
        await fixture.bridge.settleIntentTransactions(deadlineSeconds: 0.2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            1.0,
            "Quitting must never await a stuck store operation, in any shutdown phase."
        )
        _ = await occupier.value
    }
}
