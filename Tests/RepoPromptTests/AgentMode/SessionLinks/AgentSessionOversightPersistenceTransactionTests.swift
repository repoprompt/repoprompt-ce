import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Durable-intent transaction semantics around Add and Stop.
///
/// The ordering is the contract: a reported Add implies a committed insert *before* anything was
/// reserved, and a reported Stop implies a committed removal before token A's grants were revoked.
/// Everything the later launch coordinator does assumes exactly this, so these are the cheapest
/// place to pin it.
@MainActor
final class AgentSessionOversightPersistenceTransactionTests: XCTestCase {
    // MARK: - Fake host

    private final class FakeHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        /// Answers by call index so a test can make an endpoint disappear at one exact point in the
        /// Add flow — the establishment re-reads candidates after reserving, and that is the window
        /// a durable insert has to be able to compensate itself out of.
        var candidatesByCall: ((Int) -> [AgentSessionLinkEndpointCandidate])?
        private(set) var candidateCallCount = 0
        /// Lets a test land endpoint or eligibility drift in the final post-activation tail, when
        /// the bridge invalidates the target's tool advertisement after projection publication.
        var onToolAdvertisementInvalidation: ((UUID) -> Void)?

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            candidateCallCount += 1
            return candidatesByCall?(candidateCallCount) ?? candidates
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

    /// Lets one test fail exactly the write it cares about, without failing the setup writes.
    private final class WriteGate: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldFail = false

        var failsNextWrites: Bool {
            get { lock.withLock { shouldFail } }
            set { lock.withLock { shouldFail = newValue } }
        }

        func write(_ data: Data, to url: URL) throws {
            if failsNextWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let bridge: AgentSessionLinkRuntimeBridge
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeHost
        let store: AgentSessionOversightIntentStore
        let gate: WriteGate
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
            .appendingPathComponent("oversight-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeCandidate(
        windowID: Int,
        displayName: String,
        sessionID: UUID = UUID()
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: sessionID,
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

    private func replacingOutboundMonitoringRole(
        of candidate: AgentSessionLinkEndpointCandidate,
        allowed: Bool
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: candidate.persistentBindingGeneration,
            bindingTransitionGeneration: candidate.bindingTransitionGeneration,
            isTopLevel: candidate.isTopLevel,
            hasLoadedPersistedState: candidate.hasLoadedPersistedState,
            bindingTransitionInProgress: candidate.bindingTransitionInProgress,
            isClosing: candidate.isClosing,
            isMCPControlled: candidate.isMCPControlled,
            isMCPOriginated: candidate.isMCPOriginated,
            roleAllowsOutboundMonitoring: allowed,
            displayName: candidate.displayName,
            providerDisplayName: candidate.providerDisplayName,
            locationLabel: candidate.locationLabel
        )
    }

    private func makeFixture(mode: AgentSessionOversightPersistenceMode = .enabled) -> Fixture {
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
        let gate = WriteGate()
        let store = AgentSessionOversightIntentStore(
            fileURL: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
            mode: mode,
            writer: { data, url in try gate.write(data, to: url) }
        )
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { [weak host] sessionID in
                await MainActor.run {
                    host?.onToolAdvertisementInvalidation?(sessionID)
                }
            }
        )
        bridge.installIntentStore(store)
        return Fixture(
            bridge: bridge,
            authority: authority,
            host: host,
            store: store,
            gate: gate,
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

    private func stop(
        _ fixture: Fixture,
        linkID: UUID,
        generation: UInt64
    ) async -> AgentMonitorStopOutcome {
        await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: DomainAgentSessionLinkReference(
                linkID: linkID,
                generation: generation
            )
        )
    }

    private func liveReference(_ fixture: Fixture) async -> DomainAgentSessionLinkReference? {
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        guard let item = inventory.items.first(where: { $0.targetSessionID == fixture.target.sessionID })
        else { return nil }
        return DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
    }

    // MARK: - Tests

    func testAddPersistsIntentAndStopRemovesItBeforeTheGrantIsRevoked() async throws {
        let fixture = makeFixture()

        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let tokenAfterAdd = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(tokenAfterAdd, "A reported Add implies a committed insert.")
        let liveAfterAdd = await liveReference(fixture)
        let reference = try XCTUnwrap(liveAfterAdd)

        let outcome = await stop(fixture, linkID: reference.linkID, generation: reference.generation)

        let tokenAfterStop = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertNil(tokenAfterStop)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
    }

    func testAddIsRefusedAndNothingIsGrantedWhenTheDurableWriteFails() async {
        let fixture = makeFixture()
        _ = await fixture.store.loadForLaunch()
        fixture.gate.failsNextWrites = true

        let outcome = await add(fixture)

        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(outcome.failureMessage, AgentSessionOversightPersistenceCopy.addWriteFailed)
        XCTAssertNil(token)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty, "Persistence commits before the reservation, so nothing may be granted.")
    }

    func testStopWriteFailureLeavesBothTheGrantAndTheSavedIntentIntact() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let currentToken = await fixture.store.token(for: fixture.pair)
        let token = try XCTUnwrap(currentToken)
        fixture.gate.failsNextWrites = true

        let outcome = await stop(fixture, linkID: reference.linkID, generation: reference.generation)

        let tokenAfterStop = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(outcome, .failed(message: AgentSessionOversightPersistenceCopy.stopWriteFailed))
        XCTAssertEqual(tokenAfterStop, token)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertEqual(inventory.items.count, 1, "A Stop that could not commit must not report the link gone.")
    }

    func testExactStopEndpointMismatchLeavesTheDurableTokenAndGrantIntact() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let storedTokenBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedTokenBefore)
        let wrongObserver = makeCandidate(
            windowID: 9,
            displayName: "Wrong observer incarnation",
            sessionID: fixture.observer.sessionID
        )

        let outcome = await fixture.bridge.stopMonitorLink(
            observerEndpoint: wrongObserver.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: reference
        )

        XCTAssertEqual(
            outcome,
            .failed(message: "That oversight relationship is no longer active.")
        )
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertEqual(tokenAfter, tokenBefore)
        XCTAssertEqual(activeGrant?.observer, fixture.observer.domainEndpoint)
        XCTAssertEqual(activeGrant?.target, fixture.target.domainEndpoint)
    }

    func testDeadObserverExactStopRemovesDurableIntentBeforeRevokingGrant() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        fixture.host.candidates = [fixture.target]

        let outcome = await stop(
            fixture,
            linkID: reference.linkID,
            generation: reference.generation
        )

        XCTAssertEqual(outcome, .stopped)
        let token = await fixture.store.token(for: fixture.pair)
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertNil(token)
        XCTAssertNil(activeGrant)
    }

    func testAuthorityActiveExactStopRevokesItsGrantWhenTheDurableRowIsAlreadyAbsent() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let storedToken = await fixture.store.token(for: fixture.pair)
        let token = try XCTUnwrap(storedToken)
        let externalRemoval = await fixture.store.remove(fixture.pair, ifCurrent: token)
        XCTAssertEqual(externalRemoval.outcome, .applied)

        let outcome = await stop(
            fixture,
            linkID: reference.linkID,
            generation: reference.generation
        )

        XCTAssertEqual(outcome, .stopped)
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertNil(tokenAfter)
        XCTAssertNil(activeGrant, "An authority-active reference must not survive an absent durable row.")
    }

    func testAuthorityActiveExactStopRevokesOnlyItsGrantWhenANewerTokenIsDurable() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let storedTokenA = await fixture.store.token(for: fixture.pair)
        let tokenA = try XCTUnwrap(storedTokenA)
        let externalRemoval = await fixture.store.remove(fixture.pair, ifCurrent: tokenA)
        XCTAssertEqual(externalRemoval.outcome, .applied)
        let replacementInsertion = await fixture.store.insert(fixture.pair)
        XCTAssertEqual(replacementInsertion.outcome, .applied)
        let storedTokenB = await fixture.store.token(for: fixture.pair)
        let tokenB = try XCTUnwrap(storedTokenB)
        XCTAssertNotEqual(tokenA, tokenB)

        let outcome = await stop(
            fixture,
            linkID: reference.linkID,
            generation: reference.generation
        )

        XCTAssertEqual(outcome, .stopped)
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertEqual(tokenAfter, tokenB, "The stale reference must not delete the newer durable token.")
        XCTAssertNil(activeGrant, "The authority-validated expected reference must still be revoked.")
    }

    /// Add commits its insert before reserving, so a failure after that point owes a compensation:
    /// otherwise a link the user was told did not start would silently come back next launch.
    func testEstablishmentFailureAfterTheDurableInsertCompensatesItsOwnToken() async {
        let fixture = makeFixture()
        let everything = fixture.host.candidates
        let withoutTarget = everything.filter { $0.sessionID != fixture.target.sessionID }
        // Calls 1 and 2 are the preflight and the establishment's own resolution; call 3 is the
        // live re-read between reservation and seed, which is where a real rebind would land.
        fixture.host.candidatesByCall = { call in call >= 3 ? withoutTarget : everything }

        let outcome = await add(fixture)

        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(outcome, .failed(.rebinding))
        XCTAssertNil(token, "A failed establishment must compensate the intent it durably inserted.")
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty, "The rolled-back reservation must leave no grant behind.")
    }

    func testSidebarAddCompensatesItsTokenWhenObserverLosesFinalLinkBeforeActivation() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("setup link failed") }
        let currentReference = await liveReference(fixture)
        let existingReference = try XCTUnwrap(currentReference)
        let newTarget = makeCandidate(windowID: 3, displayName: "New target")
        fixture.host.candidates = [fixture.observer, fixture.target, newTarget]
        let newPair = AgentSessionOversightIntent(
            observerSessionID: fixture.observer.sessionID,
            targetSessionID: newTarget.sessionID
        )
        var stopOutcome: AgentMonitorStopOutcome?
        fixture.bridge.test_afterReservationBeforeActivation = { pendingPair in
            guard pendingPair == newPair, stopOutcome == nil else { return }
            let insertedToken = await fixture.store.token(for: newPair)
            XCTAssertNotNil(insertedToken, "sidebar Add must persist before reserving")
            stopOutcome = await fixture.bridge.stopMonitorLink(
                observerEndpoint: fixture.observer.domainEndpoint,
                targetEndpoint: fixture.target.domainEndpoint,
                expectedReference: existingReference
            )
        }

        let outcome = await fixture.bridge.addSidebarMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: newTarget.domainEndpoint
        )

        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertEqual(
            outcome,
            .rejected(message: AgentSessionLinkRuntimeBridge.existingOverseerRequiredMessage)
        )
        let oldToken = await fixture.store.token(for: fixture.pair)
        let newToken = await fixture.store.token(for: newPair)
        XCTAssertNil(oldToken)
        XCTAssertNil(newToken, "failed sidebar Add must compensate its newly inserted durable token")
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testIdempotentExpectedEndpointAddFailureDoesNotCompensateExistingIntent() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let storedTokenBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedTokenBefore)
        let referenceBefore = await liveReference(fixture)
        let baseCandidateReads = fixture.host.candidateCallCount
        let allCandidates = fixture.host.candidates
        fixture.host.candidatesByCall = { call in
            // The constrained Add preflight succeeds. After its `.unchanged` durable reassertion, the
            // establishment's fresh resolver sees a transiently unavailable target.
            call >= baseCandidateReads + 2
                ? allCandidates.filter { $0.sessionID != fixture.target.sessionID }
                : allCandidates
        }

        let outcome = await fixture.bridge.addMonitorLink(
            pair: fixture.pair,
            expectedObserverEndpoint: fixture.observer.domainEndpoint,
            expectedTargetEndpoint: fixture.target.domainEndpoint
        )

        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let referenceAfter = await liveReference(fixture)
        XCTAssertEqual(outcome, .failed(.notFound))
        XCTAssertEqual(
            tokenAfter,
            tokenBefore,
            "A failed idempotent reassertion must not compensate a durable row it did not insert."
        )
        XCTAssertEqual(referenceAfter, referenceBefore, "The pre-existing authority grant remains live.")
    }

    func testConcurrentExactIncarnationsCannotShareOneDurablePairToken() async throws {
        let fixture = makeFixture()
        let duplicateObserver = makeCandidate(
            windowID: 3,
            displayName: "Planning duplicate",
            sessionID: fixture.observer.sessionID
        )
        fixture.host.candidates = [fixture.observer, duplicateObserver, fixture.target]

        let reservationFence = TestReleaseFence(name: "winning exact Add reservation")
        let pairWaitFence = TestReleaseFence(name: "sibling exact Add pair wait")
        defer {
            pairWaitFence.release()
            reservationFence.release()
        }
        var shouldFenceWinningReservation = true
        fixture.bridge.test_afterReservationBeforeActivation = { pair in
            guard pair == fixture.pair, shouldFenceWinningReservation else { return }
            shouldFenceWinningReservation = false
            await reservationFence.enterAndWait()
        }
        fixture.bridge.test_beforePairEstablishmentWait = { pair in
            guard pair == fixture.pair else { return }
            await pairWaitFence.enterAndWait()
        }

        let winningAdd = Task { @MainActor in
            await fixture.bridge.addMonitorLink(
                observerEndpoint: fixture.observer.domainEndpoint,
                targetEndpoint: fixture.target.domainEndpoint
            )
        }
        await reservationFence.waitUntilEntered()
        let authorityWhileWinnerIsParked = await fixture.authority.snapshot()
        XCTAssertEqual(authorityWhileWinnerIsParked.activeLinkCount, 0)
        XCTAssertEqual(authorityWhileWinnerIsParked.pendingReservationCount, 1)
        let storedTokenBeforeSibling = await fixture.store.token(for: fixture.pair)
        let tokenBeforeSibling = try XCTUnwrap(storedTokenBeforeSibling)
        let assertionBeforeSibling = await fixture.store.assertionGeneration(for: fixture.pair)

        let siblingAdd = Task { @MainActor in
            await fixture.bridge.addMonitorLink(
                observerEndpoint: duplicateObserver.domainEndpoint,
                targetEndpoint: fixture.target.domainEndpoint
            )
        }
        await pairWaitFence.waitUntilEntered()
        let tokenWhileSiblingWaits = await fixture.store.token(for: fixture.pair)
        let assertionWhileSiblingWaits = await fixture.store.assertionGeneration(for: fixture.pair)
        let authorityWhileSiblingWaits = await fixture.authority.snapshot()
        XCTAssertEqual(tokenWhileSiblingWaits, tokenBeforeSibling)
        XCTAssertEqual(
            assertionWhileSiblingWaits,
            assertionBeforeSibling,
            "A waiting sibling incarnation must not reassert the shared durable token."
        )
        XCTAssertEqual(authorityWhileSiblingWaits.activeLinkCount, 0)
        XCTAssertEqual(
            authorityWhileSiblingWaits.pendingReservationCount,
            1,
            "The sibling incarnation must not reserve alongside the winning semantic pair owner."
        )

        pairWaitFence.release()
        reservationFence.release()

        let winningOutcome = await winningAdd.value
        let siblingOutcome = await siblingAdd.value
        guard case let .added(linkID, _) = winningOutcome else {
            return XCTFail("Expected the first exact incarnation to win: \(winningOutcome)")
        }
        XCTAssertEqual(siblingOutcome, .failed(.rebinding))
        let tokenAfterSibling = await fixture.store.token(for: fixture.pair)
        let assertionAfterSibling = await fixture.store.assertionGeneration(for: fixture.pair)
        XCTAssertEqual(tokenAfterSibling, tokenBeforeSibling)
        XCTAssertEqual(assertionAfterSibling, assertionBeforeSibling)

        let winningInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let winningItem = try XCTUnwrap(winningInputs.outbound.items.first)
        XCTAssertEqual(winningItem.linkID, linkID)
        let siblingInputs = await fixture.authority.projectionInputs(
            forEndpoint: duplicateObserver.domainEndpoint
        )
        XCTAssertTrue(siblingInputs.outbound.items.isEmpty)

        let stopOutcome = await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: DomainAgentSessionLinkReference(
                linkID: winningItem.linkID,
                generation: winningItem.generation
            )
        )

        XCTAssertEqual(stopOutcome, .stopped)
        let tokenAfterStop = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(tokenAfterStop)
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testUnconstrainedAndExactAddsShareSemanticPairEstablishmentOwnership() async throws {
        let fixture = makeFixture()
        let duplicateObserver = makeCandidate(
            windowID: 3,
            displayName: "Planning duplicate",
            sessionID: fixture.observer.sessionID
        )
        let reservationFence = TestReleaseFence(name: "unconstrained Add reservation")
        let pairWaitFence = TestReleaseFence(name: "exact Add pair wait")
        defer {
            pairWaitFence.release()
            reservationFence.release()
        }
        var shouldFenceReservation = true
        fixture.bridge.test_afterReservationBeforeActivation = { pair in
            guard pair == fixture.pair, shouldFenceReservation else { return }
            shouldFenceReservation = false
            await reservationFence.enterAndWait()
        }
        fixture.bridge.test_beforePairEstablishmentWait = { pair in
            guard pair == fixture.pair else { return }
            await pairWaitFence.enterAndWait()
        }

        let unconstrainedAdd = Task { @MainActor in
            await add(fixture)
        }
        await reservationFence.waitUntilEntered()
        let authorityWhileWinnerIsParked = await fixture.authority.snapshot()
        XCTAssertEqual(authorityWhileWinnerIsParked.activeLinkCount, 0)
        XCTAssertEqual(authorityWhileWinnerIsParked.pendingReservationCount, 1)
        let storedTokenBeforeSibling = await fixture.store.token(for: fixture.pair)
        let tokenBeforeSibling = try XCTUnwrap(storedTokenBeforeSibling)
        let assertionBeforeSibling = await fixture.store.assertionGeneration(for: fixture.pair)
        fixture.host.candidates = [fixture.observer, duplicateObserver, fixture.target]

        let exactSiblingAdd = Task { @MainActor in
            await fixture.bridge.addMonitorLink(
                observerEndpoint: duplicateObserver.domainEndpoint,
                targetEndpoint: fixture.target.domainEndpoint
            )
        }
        await pairWaitFence.waitUntilEntered()
        let tokenWhileSiblingWaits = await fixture.store.token(for: fixture.pair)
        let assertionWhileSiblingWaits = await fixture.store.assertionGeneration(for: fixture.pair)
        let authorityWhileSiblingWaits = await fixture.authority.snapshot()
        XCTAssertEqual(tokenWhileSiblingWaits, tokenBeforeSibling)
        XCTAssertEqual(
            assertionWhileSiblingWaits,
            assertionBeforeSibling,
            "An exact Add must not reassert a token owned by an in-flight unconstrained Add."
        )
        XCTAssertEqual(authorityWhileSiblingWaits.activeLinkCount, 0)
        XCTAssertEqual(authorityWhileSiblingWaits.pendingReservationCount, 1)

        pairWaitFence.release()
        reservationFence.release()

        let unconstrainedOutcome = await unconstrainedAdd.value
        let siblingOutcome = await exactSiblingAdd.value
        guard case .added = unconstrainedOutcome else {
            return XCTFail("Expected the unconstrained incarnation to win: \(unconstrainedOutcome)")
        }
        XCTAssertEqual(siblingOutcome, .failed(.rebinding))
        let tokenAfterSibling = await fixture.store.token(for: fixture.pair)
        let assertionAfterSibling = await fixture.store.assertionGeneration(for: fixture.pair)
        XCTAssertEqual(tokenAfterSibling, tokenBeforeSibling)
        XCTAssertEqual(assertionAfterSibling, assertionBeforeSibling)

        let winningInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let winningItem = try XCTUnwrap(winningInputs.outbound.items.first)
        let siblingInputs = await fixture.authority.projectionInputs(
            forEndpoint: duplicateObserver.domainEndpoint
        )
        XCTAssertTrue(siblingInputs.outbound.items.isEmpty)

        let stopOutcome = await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: DomainAgentSessionLinkReference(
                linkID: winningItem.linkID,
                generation: winningItem.generation
            )
        )

        XCTAssertEqual(stopOutcome, .stopped)
        let tokenAfterStop = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(tokenAfterStop)
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testPostActivationEndpointDriftPreservesPreloadedDurableIntent() async throws {
        let fixture = makeFixture()
        _ = await fixture.store.loadForLaunch()
        let preload = await fixture.store.insert(fixture.pair)
        XCTAssertEqual(preload.outcome, .applied)
        let storedTokenBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedTokenBefore)
        let assertionBefore = await fixture.store.assertionGeneration(for: fixture.pair)
        let replacementTarget = makeCandidate(
            windowID: 9,
            displayName: "Replacement target",
            sessionID: fixture.target.sessionID
        )
        var shouldDrift = true
        fixture.bridge.test_afterActivationBeforeDeletionFence = { pair in
            guard pair == fixture.pair, shouldDrift else { return }
            shouldDrift = false
            fixture.host.candidates = [fixture.observer, replacementTarget]
        }

        let outcome = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )

        XCTAssertEqual(outcome, .failed(.rebinding))
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let assertionAfter = await fixture.store.assertionGeneration(for: fixture.pair)
        XCTAssertEqual(
            tokenAfter,
            tokenBefore,
            "Exact endpoint rollback must not settle durable intent this Add only reasserted."
        )
        XCTAssertGreaterThan(
            assertionAfter,
            assertionBefore,
            "The unchanged insert remains a reassertion even though authority activation rolls back."
        )
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testPostActivationEndpointDriftCompensatesDurableIntentCreatedByAdd() async {
        let fixture = makeFixture()
        let replacementTarget = makeCandidate(
            windowID: 9,
            displayName: "Replacement target",
            sessionID: fixture.target.sessionID
        )
        var shouldDrift = true
        fixture.bridge.test_afterActivationBeforeDeletionFence = { pair in
            guard pair == fixture.pair, shouldDrift else { return }
            shouldDrift = false
            fixture.host.candidates = [fixture.observer, replacementTarget]
        }

        let outcome = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )

        XCTAssertEqual(outcome, .failed(.rebinding))
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        XCTAssertNil(
            tokenAfter,
            "Outer Add compensation must remove the durable intent this attempt created."
        )
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testPostActivationEligibilityDriftPreservesPreloadedDurableIntent() async throws {
        let fixture = makeFixture()
        _ = await fixture.store.loadForLaunch()
        let preload = await fixture.store.insert(fixture.pair)
        XCTAssertEqual(preload.outcome, .applied)
        let storedTokenBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedTokenBefore)
        let assertionBefore = await fixture.store.assertionGeneration(for: fixture.pair)
        let deniedObserver = replacingOutboundMonitoringRole(of: fixture.observer, allowed: false)
        XCTAssertEqual(deniedObserver.domainEndpoint, fixture.observer.domainEndpoint)
        fixture.host.onToolAdvertisementInvalidation = { [weak host = fixture.host] sessionID in
            guard sessionID == fixture.target.sessionID, let host else { return }
            host.onToolAdvertisementInvalidation = nil
            host.candidates = [deniedObserver, fixture.target]
        }

        let outcome = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )

        XCTAssertEqual(outcome, .failed(.rebinding))
        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let assertionAfter = await fixture.store.assertionGeneration(for: fixture.pair)
        XCTAssertEqual(
            tokenAfter,
            tokenBefore,
            "Final-tail eligibility rollback must preserve a pre-existing durable intent."
        )
        XCTAssertGreaterThan(assertionAfter, assertionBefore)
        let authoritySnapshot = await fixture.authority.snapshot()
        XCTAssertEqual(authoritySnapshot.activeLinkCount, 0)
        XCTAssertEqual(authoritySnapshot.pendingReservationCount, 0)
    }

    func testExpectedEndpointMismatchLeavesExistingGrantAndDurableAssertionUntouched() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let storedTokenBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedTokenBefore)
        let assertionBefore = await fixture.store.assertionGeneration(for: fixture.pair)
        let liveBefore = await liveReference(fixture)
        let referenceBefore = try XCTUnwrap(liveBefore)
        let replacementObserver = makeCandidate(
            windowID: 9,
            displayName: "Replacement observer",
            sessionID: fixture.observer.sessionID
        )
        fixture.host.candidates = [replacementObserver, fixture.target]

        let outcome = await fixture.bridge.addMonitorLink(
            pair: fixture.pair,
            expectedObserverEndpoint: replacementObserver.domainEndpoint,
            expectedTargetEndpoint: fixture.target.domainEndpoint
        )

        let tokenAfter = await fixture.store.token(for: fixture.pair)
        let assertionAfter = await fixture.store.assertionGeneration(for: fixture.pair)
        let referenceAfter = await liveReference(fixture)
        XCTAssertEqual(outcome, .failed(.rebinding))
        XCTAssertEqual(tokenAfter, tokenBefore)
        XCTAssertEqual(
            assertionAfter,
            assertionBefore,
            "The mismatch must be detected inside the pair lane before durable reassertion."
        )
        XCTAssertEqual(referenceAfter, referenceBefore)
        let originalInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertEqual(originalInputs.outbound.items.count, 1)
    }

    func testImmediateReAddAfterStopAllocatesANewTokenTheOldOneCannotDelete() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let storedTokenA = await fixture.store.token(for: fixture.pair)
        let tokenA = try XCTUnwrap(storedTokenA)
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let stopOutcome = await stop(fixture, linkID: reference.linkID, generation: reference.generation)
        XCTAssertEqual(stopOutcome, .stopped)

        guard case .added = await add(fixture) else { return XCTFail("Expected the re-add to succeed") }
        let storedTokenB = await fixture.store.token(for: fixture.pair)
        let tokenB = try XCTUnwrap(storedTokenB)
        let staleRemoval = await fixture.store.remove(fixture.pair, ifCurrent: tokenA)
        let currentToken = await fixture.store.token(for: fixture.pair)

        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertEqual(staleRemoval.outcome, .tokenMismatch)
        XCTAssertEqual(currentToken, tokenB)
    }

    /// The freeze is rechecked at every phase, not only at admission.
    ///
    /// Landing it between the reservation and the activation is the case that matters: the
    /// reservation authorizes nothing, so the fence must abandon it instead of going on to create a
    /// grant during shutdown — while the insert that already committed is preserved for the next
    /// launch rather than compensated away.
    func testFreezeBetweenReservationAndActivationGrantsNothingAndPreservesTheToken() async {
        let fixture = makeFixture()
        let everything = fixture.host.candidates
        // Call 3 is the live re-read the establishment performs immediately after reserving.
        fixture.host.candidatesByCall = { [weak bridge = fixture.bridge] call in
            if call == 3 { bridge?.freezeForTermination() }
            return everything
        }

        let outcome = await add(fixture)

        XCTAssertEqual(
            outcome.failureMessage,
            AgentSessionOversightPersistenceCopy.shutdownAfterInsert
        )
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty, "Nothing may be activated after the freeze.")
        let token = await fixture.store.token(for: fixture.pair)
        XCTAssertNotNil(
            token,
            "A committed insert is preserved for the next launch, not compensated away by shutdown."
        )
    }

    /// A stale row for reference A can be clicked long after the pair was stopped and re-added.
    ///
    /// Deriving the durable token from the *pair* would find token B, remove it, settle B's
    /// establishment, and revoke B's grants — a stale UI action terminating a newer explicit re-add.
    func testAStaleRowsStopCannotRemoveTheTokenAReAddInstalled() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let firstLive = await liveReference(fixture)
        let stale = try XCTUnwrap(firstLive)
        let firstStop = await stop(fixture, linkID: stale.linkID, generation: stale.generation)
        XCTAssertEqual(firstStop, .stopped)
        guard case .added = await add(fixture) else { return XCTFail("Expected the re-add to succeed") }
        let storedTokenB = await fixture.store.token(for: fixture.pair)
        let tokenB = try XCTUnwrap(storedTokenB)

        let outcome = await stop(fixture, linkID: stale.linkID, generation: stale.generation)

        XCTAssertEqual(outcome, .alreadyStopped)
        let currentToken = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(currentToken, tokenB, "A stale reference must never delete a newer token.")
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertEqual(inventory.items.count, 1, "The newer grant must survive a stale Stop.")
    }

    /// Lifecycle invalidation captures assertion generation before its authority hop. The gate parks
    /// stale cleanup after revocation but before its pair lane, then an explicit Add reasserts the
    /// exact same token. Cleanup must compare out instead of deleting the user's newer assertion.
    func testLifecycleCleanupCannotDeleteASameTokenReassertion() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let storedBefore = await fixture.store.token(for: fixture.pair)
        let tokenBefore = try XCTUnwrap(storedBefore)
        let assertionBefore = await fixture.store.assertionGeneration(for: fixture.pair)
        let fence = TestReleaseFence(name: "lifecycle durable settlement")
        fixture.bridge.test_beforeDurableIntentSettlement = { pair in
            guard pair == fixture.pair else { return }
            await fence.enterAndWait()
        }

        let invalidation = Task { @MainActor in
            await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
        }
        await fence.waitUntilEntered()

        let reassertion = Task { @MainActor in await add(fixture) }
        try await AsyncTestWait.waitUntil("same-token intent reassertion") {
            await fixture.store.assertionGeneration(for: fixture.pair) > assertionBefore
        }
        let storedAfterInsert = await fixture.store.token(for: fixture.pair)
        let tokenAfterInsert = try XCTUnwrap(storedAfterInsert)
        XCTAssertEqual(tokenAfterInsert, tokenBefore, "Idempotent reassertion deliberately reuses the token.")

        fence.release()
        await invalidation.value
        let reasserted = await reassertion.value
        guard reasserted.failureMessage == nil else {
            return XCTFail("Expected reassertion to succeed, got \(reasserted)")
        }

        let tokenAfterCleanup = await fixture.store.token(for: fixture.pair)
        XCTAssertEqual(tokenAfterCleanup, tokenBefore)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertEqual(inventory.items.count, 1, "Stale cleanup must not revoke or strand the reasserted grant.")
    }

    func testStopAfterActivationSettlesWithoutDeadlockOrStaleAddSuccess() async throws {
        let fixture = makeFixture()
        let fence = TestReleaseFence(name: "post-activation stop fence")
        fixture.bridge.test_afterActivationBeforeDeletionFence = { pair in
            guard pair == fixture.pair else { return }
            await fence.enterAndWait()
        }
        let addTask = Task { @MainActor in await add(fixture) }
        await fence.waitUntilEntered()
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)

        let stopTask = Task { @MainActor in
            await stop(fixture, linkID: reference.linkID, generation: reference.generation)
        }
        try await AsyncTestWait.waitUntil("Stop durable removal") {
            await fixture.store.token(for: fixture.pair) == nil
        }
        fence.release()

        let addOutcome = await addTask.value
        let stopOutcome = await stopTask.value
        XCTAssertNotNil(addOutcome.failureMessage, "The completed task may not replay stale Add success.")
        XCTAssertTrue(stopOutcome == .stopped || stopOutcome == .alreadyStopped)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
    }

    func testStoppingAnAlreadyRevokedRowReportsAlreadyStoppedRatherThanFailing() async throws {
        let fixture = makeFixture()
        guard case .added = await add(fixture) else { return XCTFail("Expected the link to be added") }
        let live = await liveReference(fixture)
        let reference = try XCTUnwrap(live)
        let first = await stop(fixture, linkID: reference.linkID, generation: reference.generation)
        XCTAssertEqual(first, .stopped)

        let repeated = await stop(fixture, linkID: reference.linkID, generation: reference.generation)

        XCTAssertEqual(repeated, .alreadyStopped)
    }

    func testSuppressedLaunchRefusesAddWithoutReservingAnything() async {
        let fixture = makeFixture(mode: .suppressed)

        let outcome = await add(fixture)

        XCTAssertEqual(outcome.failureMessage, AgentSessionOversightPersistenceCopy.suppressedLaunch)
        let inventory = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(inventory.items.isEmpty)
    }

    func testBlockedStorePreservesTheFileAndRefusesAdd() async throws {
        let fileURL = directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)
        try Data(#"{"version":99,"links":[]}"#.utf8).write(to: fileURL, options: .atomic)
        let fixture = makeFixture()

        let outcome = await add(fixture)

        XCTAssertEqual(outcome.failureMessage, AgentSessionOversightPersistenceCopy.futureSchema)
        XCTAssertEqual(
            try String(data: Data(contentsOf: fileURL), encoding: .utf8),
            #"{"version":99,"links":[]}"#
        )
    }
}
