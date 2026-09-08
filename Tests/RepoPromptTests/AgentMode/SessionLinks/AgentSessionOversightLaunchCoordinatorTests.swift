import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Bounded, reason-aware automatic reauthorization of the launch snapshot.
///
/// The contracts pinned here are the ones a wrong implementation gets *silently* wrong: reserving
/// before a barrier, force-hydrating a lazy tab, deleting a saved link because a window that was
/// abandoned rather than observed did not come back, and requeueing an entry after the user watched
/// oversight end.
@MainActor
final class AgentSessionOversightLaunchCoordinatorTests: XCTestCase {
    // MARK: - Fake host

    /// Endpoint host with a full window topology: descriptors, discovery levels, and a restore
    /// topology reason. The focused bridge tests elsewhere rely on the protocol defaults instead.
    private final class FakeHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        /// Answers by call index so a test can make an endpoint drift at one exact point between the
        /// coordinator's classification and the shared establishment path's own resolution.
        var candidatesByCall: ((Int) -> [AgentSessionLinkEndpointCandidate])?
        private(set) var candidateCallCount = 0
        var descriptors: [AgentSessionLinkComposeTabDescriptor] = []
        var discovery: [AgentSessionLinkDiscoveryState] = []
        var topology: AgentSessionOversightRestoreTopologyState = .completeAllEntriesConsumed
        private(set) var publishedPresentations: [AgentSessionOversightPersistencePresentation] = []

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            candidateCallCount += 1
            return candidatesByCall?(candidateCallCount) ?? candidates
        }

        func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
            descriptors
        }

        func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState] {
            discovery
        }

        func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState {
            topology
        }

        func agentSessionLinkPublishPersistencePresentation(
            _ presentation: AgentSessionOversightPersistencePresentation
        ) {
            publishedPresentations.append(presentation)
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

    private var directory: URL!
    private var observerSessionID = UUID()
    private var targetSessionID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oversight-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observerSessionID = UUID()
        targetSessionID = UUID()
        AgentSessionDeletionRegistry.shared.test_reset()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        AgentSessionDeletionRegistry.shared.test_reset()
        try super.tearDownWithError()
    }

    private var pair: AgentSessionOversightIntent {
        AgentSessionOversightIntent(
            observerSessionID: observerSessionID,
            targetSessionID: targetSessionID
        )
    }

    /// Seeds the durable manifest so the launch load produces exactly this one saved pair.
    private func seedSavedPair() throws {
        let document = AgentSessionOversightIntentDocument(links: [pair])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(
            to: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            options: .atomic
        )
    }

    /// A live, eligible candidate whose hydration proof matches its own current binding, which is
    /// the only shape automatic restoration accepts.
    private func makeReadyCandidate(windowID: Int, sessionID: UUID) -> AgentSessionLinkEndpointCandidate {
        let tabID = UUID()
        return AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: tabID,
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
            displayName: "Session \(windowID)",
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main",
            restorationReadiness: .authoritative(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: tabID,
                        sessionID: sessionID
                    ),
                    bindingTransitionGeneration: 1
                ),
                .persistedPayloadApplied
            )
        )
    }

    /// The same live incarnation with a different hydration proof.
    ///
    /// Byte-for-byte identical endpoint identity is the whole point: the resolver cannot tell these
    /// apart, because it gates on the legacy `hasLoadedPersistedState` latch, which stays `true`.
    private func withReadiness(
        _ candidate: AgentSessionLinkEndpointCandidate,
        _ readiness: AgentSessionRestorationReadiness
    ) -> AgentSessionLinkEndpointCandidate {
        var copy = candidate
        copy.restorationReadiness = readiness
        return copy
    }

    private func descriptor(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionLinkComposeTabDescriptor {
        AgentSessionLinkComposeTabDescriptor(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID
        )
    }

    private struct Fixture {
        let bridge: AgentSessionLinkRuntimeBridge
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeHost
        let store: AgentSessionOversightIntentStore
        let gate: WriteGate
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
        host.discovery = [
            AgentSessionLinkDiscoveryState(
                epoch: AgentSessionLinkDiscoveryEpoch(windowID: 1, workspaceID: UUID(), generation: 1),
                isComplete: true
            )
        ]
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
            toolAdvertisementInvalidator: { _ in }
        )
        return Fixture(bridge: bridge, authority: authority, host: host, store: store, gate: gate)
    }

    private func isRestored(_ fixture: Fixture) async -> Bool {
        let inventory = await fixture.authority.links(forObserver: observerSessionID)
        return inventory.items.contains { $0.targetSessionID == targetSessionID }
    }

    // MARK: - Barriers

    func testNothingIsReservedWhileTheRestoreTopologyIsStillPending() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .pending
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored, "Automatic restore may not reserve before the outer topology settles.")
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
    }

    func testNothingIsReservedWhileAWindowsDiscoveryLevelIsIncomplete() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.discovery = [
            AgentSessionLinkDiscoveryState(
                epoch: AgentSessionLinkDiscoveryEpoch(windowID: 1, workspaceID: UUID(), generation: 2),
                isComplete: false
            )
        ]
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    // MARK: - Lazy background tabs

    /// The behaviour the whole descriptor mechanism exists for: a saved session that is *present* but
    /// unhydrated must be waited for, never force-loaded and never declared missing.
    func testALazyBackgroundTabWaitsAndThenActivatesExactlyOnceWhenItHydrates() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lazyTabID = UUID()
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [
            descriptor(for: observer),
            AgentSessionLinkComposeTabDescriptor(
                windowID: 2,
                workspaceID: UUID(),
                tabID: lazyTabID,
                sessionID: targetSessionID
            )
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        var restored = await isRestored(fixture)
        XCTAssertFalse(restored, "A described-but-unhydrated tab must be waited for, not resolved.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let tokenWhileWaiting = await fixture.store.token(for: pair)
        XCTAssertNotNil(tokenWhileWaiting, "Waiting must never delete the saved intent.")

        // The user visits the tab: it hydrates and becomes a live authoritative candidate.
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    func testInProgressDeletionKeepsLaunchIntentWaitingAndFailureRestoresIt() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        var target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let attempt = AgentSessionDeletionRegistry.shared
            .beginDurableDeletion(sessionID: targetSessionID)
        target.isDeletionInProgress = true
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
        let tokenWhileDeleting = await fixture.store.token(for: pair)
        XCTAssertNotNil(tokenWhileDeleting, "A reversible attempt must not retire durable intent.")

        AgentSessionDeletionRegistry.shared.didFailDurableDeletion(attempt)
        target.isDeletionInProgress = false
        fixture.host.candidates = [observer, target]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
        let tokenAfterFailure = await fixture.store.token(for: pair)
        XCTAssertEqual(tokenAfterFailure, tokenWhileDeleting)
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
    }

    // MARK: - Absence

    func testAMissingSessionIsRemovedOnlyWhenTheTopologyProvesAbsence() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 1)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let survived = await fixture.store.token(for: pair)
        XCTAssertNotNil(survived, "Abandoned leftovers cannot prove absence, so the intent must survive.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
    }

    func testAMissingSessionIsTerminalUnderAllEntriesConsumed() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.missing))
    }

    /// A duplicate is a positive fact even under an uncertain topology.
    func testADuplicateLiveIncarnationTerminatesEvenWhenAbsenceIsUncertain() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 2)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target, duplicate]
        fixture.host.descriptors = [
            descriptor(for: observer),
            descriptor(for: target),
            descriptor(for: duplicate)
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.ambiguousDuplicate))
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    func testATerminalHydrationProofTerminatesTheEntryDespiteALiveCandidate() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let failedTabID = UUID()
        let failed = AgentSessionLinkEndpointCandidate(
            windowID: 2,
            workspaceID: UUID(),
            tabID: failedTabID,
            sessionID: targetSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            // The legacy completion latch is true; only the binding-qualified proof knows better.
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main",
            restorationReadiness: .terminal(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: failedTabID,
                        sessionID: targetSessionID
                    ),
                    bindingTransitionGeneration: 1
                ),
                .loadFailed
            )
        )
        fixture.host.candidates = [observer, failed]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: failed)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.hydrationFailed))
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    // MARK: - At most once

    /// The user watched oversight end. It must not silently come back on the next readiness event.
    func testALaterRevocationTerminalizesTheEntryAndIsNeverRequeued() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        var restored = await isRestored(fixture)
        XCTAssertTrue(restored)

        // The observer's window closes.
        await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
        fixture.host.candidates = [target]
        fixture.host.descriptors = [descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token, "An ordinary window close ends the saved relationship.")
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)

        // Everything comes back. The retired entry must not reserve a second time.
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    // MARK: - Proof carried through establishment

    /// Classification proving `.authoritative` is not enough on its own.
    ///
    /// The shared establishment path re-resolves with the resolver, which gates on the legacy
    /// `hasLoadedPersistedState` latch — also `true` for a missing payload, a superseded revision,
    /// and a thrown load error. Without the proof travelling into that path, an endpoint that
    /// rehydrates in place between classification and reservation is silently reauthorized.
    func testAProofThatStopsHoldingAfterClassificationBlocksTheAutomaticRestore() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let rehydrating = withReadiness(
            target,
            .pending(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: target.tabID,
                        sessionID: target.sessionID
                    ),
                    bindingTransitionGeneration: 1
                )
            )
        )
        XCTAssertEqual(
            rehydrating.domainEndpoint,
            target.domainEndpoint,
            "The identity must be unchanged, or the resolver would have caught this on its own."
        )
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        // Call 1 is the coordinator's classification; every later call is the shared path resolving.
        fixture.host.candidatesByCall = { call in
            call == 1 ? [observer, target] : [observer, rehydrating]
        }

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored, "An unproven incarnation must never be reauthorized.")
        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.activationFailed)
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
    }

    // MARK: - Active-entry audit

    /// A restored grant is re-audited, not left alone for the rest of the launch.
    func testALateDuplicateIncarnationRevokesARestoredGrantAndNeverRequeuesIt() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        var restored = await isRestored(fixture)
        XCTAssertTrue(restored)

        // The saved UUID opens a second time. Neither incarnation may be granted from here on.
        let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target, duplicate]
        fixture.host.descriptors = [
            descriptor(for: observer),
            descriptor(for: target),
            descriptor(for: duplicate)
        ]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.ambiguousDuplicate)
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(
            fixture.bridge.test_launchReservationStartCount(),
            1,
            "An audited entry is finished, never requeued."
        )
    }

    /// An ordinary close of a described-but-unhydrated tab ends the saved relationship.
    ///
    /// Nothing was ever granted, so no authority notice mentions this pair and the durable-intent
    /// settlement has nothing to remove. Under a topology that cannot prove absence the intent would
    /// otherwise survive the close and reactivate later.
    func testClosingADescribedButUnhydratedTabEndsTheWaitingIntent() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 1)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lazyTabID = UUID()
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [
            descriptor(for: observer),
            AgentSessionLinkComposeTabDescriptor(
                windowID: 2,
                workspaceID: UUID(),
                tabID: lazyTabID,
                sessionID: targetSessionID
            )
        ]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let whileWaiting = await fixture.store.token(for: pair)
        XCTAssertNotNil(whileWaiting)

        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.invalidateBinding(windowID: 2, tabID: lazyTabID, reason: .tabClosed)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.bindingDrift),
            "An endpoint observed and then torn down is a fact, not the uncertainty of an abandoned restore."
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
    }

    // MARK: - Launch policy

    func testAutoRestoreDisabledLoadsTheManifestWithoutReauthorizingAnything() async throws {
        try seedSavedPair()
        let fixture = makeFixture(mode: .dormant)
        fixture.host.topology = .dormantAutoRestoreDisabled
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "Dormant intent must survive a launch with restoration turned off.")
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.noticeMessage,
            AgentSessionOversightPersistenceCopy.autoRestoreDisabled
        )
    }

    // MARK: - Cleanup failure

    func testACleanupWriteFailureSuppressesTheEntryAndSurfacesRetrySaving() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        // Only the observer is present, under a topology that proves absence: the entry is terminal
        // and owes a durable removal, which the gate then refuses.
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true

        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A failed cleanup preserves the row; it must not be silently dropped.")
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.map(\.id),
            [AgentSessionOversightWarningID.cleanupFailed]
        )

        // Retry saving is one of the few permitted retry triggers.
        fixture.gate.failsNextWrites = false
        await fixture.bridge.retryPendingIntentCleanup()

        let afterRetry = await fixture.store.token(for: pair)
        XCTAssertNil(afterRetry)
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
    }

    /// **Retry saving** racing an explicit Add of the same pair.
    ///
    /// Both are durable mutations of one pair, so both take its retirement lane and the outcome is
    /// an invariant rather than a coin flip: whichever runs first, the user ends up with a live grant
    /// backed by a durable row. Outside the lane, a cleanup already suspended on the store actor
    /// would commit its expected-token removal *after* the Add reused that very token, deleting the
    /// intent the user just recreated.
    func testRetrySavingRacingAnExplicitAddLeavesTheReassertedPairGrantedAndDurable() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)

        // The target comes back and the user explicitly re-adds the pair, while the failed cleanup
        // is retried at the same moment.
        fixture.gate.failsNextWrites = false
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        async let retry: Void = fixture.bridge.retryPendingIntentCleanup()
        let outcome = await fixture.bridge.addMonitorLink(
            observerSessionID: observerSessionID,
            rawTargetSessionID: targetSessionID.uuidString
        )
        await retry

        guard case .added = outcome else {
            return XCTFail("Expected the explicit Add to succeed, got \(outcome)")
        }
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A stale cleanup must never delete what the user just recreated.")
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored, "The grant and the durable row must agree.")
    }
}
