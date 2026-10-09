import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Bounded, reason-aware automatic reauthorization of the launch snapshot.
///
/// The contracts pinned here are the ones a wrong implementation gets *silently* wrong: reserving
/// before a barrier, leaving a saved pair dormant because its background tab was never opened,
/// deleting a saved link because a window that was abandoned rather than observed did not come back,
/// requeueing an entry after the user watched oversight end, and dropping the user's saved
/// management / auto-approval delegation across a relaunch.
@MainActor
final class AgentSessionOversightLaunchCoordinatorTests: XCTestCase {
    // MARK: - Fake host

    /// Endpoint host with a full window topology: descriptors, discovery levels, and a restore
    /// topology reason. The focused bridge tests elsewhere rely on the protocol defaults instead.
    private final class FakeHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = [] {
            didSet {
                byEndpoint = Dictionary(candidates.map { ($0.domainEndpoint, $0) }, uniquingKeysWith: { first, _ in first })
                bySession = Dictionary(grouping: candidates, by: \.sessionID)
            }
        }

        private var byEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkEndpointCandidate] = [:]
        private var bySession: [UUID: [AgentSessionLinkEndpointCandidate]] = [:]
        private(set) var projectionCount = 0
        var beforeUUIDCensus: (() -> Void)?
        private(set) var boundedCandidateVisits = 0
        private(set) var fullCandidateVisits = 0
        private(set) var candidateCallCount = 0
        var descriptors: [AgentSessionLinkComposeTabDescriptor] = []
        var discovery: [AgentSessionLinkDiscoveryState] = []
        var topology: AgentSessionOversightRestoreTopologyState = .completeAllEntriesConsumed
        private(set) var publishedPresentations: [AgentSessionOversightPersistencePresentation] = []
        var laneCreatorByEndpoint: [DomainAgentSessionLinkEndpointIdentity: UUID] = [:]
        private(set) var providerTaskRequests = 0

        func agentSessionLinkLaneProvenance(for endpoint: DomainAgentSessionLinkEndpointIdentity) -> UUID? {
            laneCreatorByEndpoint[endpoint]
        }

        private(set) var hydrationRequests: [Set<UUID>] = []
        var hydrationHandler: ((Set<UUID>) -> Void)?

        func agentSessionLinkRequestRestorationHydration(sessionIDs: Set<UUID>) {
            hydrationRequests.append(sessionIDs)
            hydrationHandler?(sessionIDs)
        }

        func agentSessionLinkCandidate(
            for endpoint: DomainAgentSessionLinkEndpointIdentity, includeLocation _: Bool
        ) -> AgentSessionLinkEndpointCandidate? {
            let candidate = byEndpoint[endpoint]
            boundedCandidateVisits += candidate == nil ? 0 : 1
            return candidate
        }

        func agentSessionLinkCandidates(
            forSessionIDs sessionIDs: Set<UUID>, includeLocation _: Bool
        ) -> [UUID: [AgentSessionLinkEndpointCandidate]] {
            beforeUUIDCensus?()
            return Dictionary(uniqueKeysWithValues: sessionIDs.map { id in
                let matches = bySession[id] ?? []
                boundedCandidateVisits += matches.count
                return (id, matches)
            })
        }

        func agentSessionLinkCandidates(includeLocation _: Bool) -> [AgentSessionLinkEndpointCandidate] {
            candidateCallCount += 1
            fullCandidateVisits += candidates.count
            return candidates
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
                board: .empty,
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
        ) {
            projectionCount += 1
        }

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
            providerTaskRequests += 1
            return .blocked(.shuttingDown)
        }

        func agentSessionLinkPerformCompact(
            to _: AgentSessionLinkEndpointCandidate,
            request _: AgentSessionLinkCompactRequest,
            liveness _: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            .blocked(.endpointInvalidated)
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
    private func makeReadyCandidate(
        windowID: Int, sessionID: UUID, workspaceID: UUID = UUID()
    ) -> AgentSessionLinkEndpointCandidate {
        let tabID = UUID()
        return AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
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

    private func makeRestoredFixture() async throws -> (
        Fixture, AgentSessionLinkEndpointCandidate, AgentSessionLinkEndpointCandidate
    ) {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        return (fixture, observer, target)
    }

    private func liveReference(_ fixture: Fixture) async -> DomainAgentSessionLinkReference? {
        let inventory = await fixture.authority.links(forObserver: observerSessionID)
        guard let item = inventory.items.first(where: { $0.targetSessionID == targetSessionID }) else { return nil }
        return DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
    }

    private func replaceTopology(_ fixture: Fixture, with candidates: [AgentSessionLinkEndpointCandidate]) {
        fixture.host.candidates = candidates
        fixture.host.descriptors = candidates.map { descriptor(for: $0) }
    }

    /// Actual bridge/authority/launch reconciliation with READY fake addresses, not VM routing,
    /// provider startup or painted UI. Keep one representative scale fixture and explicit budgets.
    func testScaleRestoreRefreshAndMenuBudgets() async throws {
        for chatCount in [30, 300] {
            let candidates = (0 ..< chatCount).map { index in
                makeReadyCandidate(windowID: index % 3 + 1, sessionID: UUID())
            }
            let intents = (0 ..< 10).map { index in
                AgentSessionOversightIntent(
                    observerSessionID: candidates[index / 2].sessionID,
                    targetSessionID: candidates[5 + index].sessionID
                )
            }
            try JSONEncoder().encode(AgentSessionOversightIntentDocument(links: intents)).write(
                to: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)
            )
            let fixture = makeFixture()
            defer { fixture.bridge.freezeForTermination() }
            fixture.host.candidates = candidates
            fixture.host.descriptors = candidates.map { descriptor(for: $0) }
            fixture.host.discovery = (1 ... 3).map { windowID in
                AgentSessionLinkDiscoveryState(
                    epoch: AgentSessionLinkDiscoveryEpoch(windowID: windowID, workspaceID: UUID(), generation: 1),
                    isComplete: true
                )
            }
            func milliseconds(since start: ContinuousClock.Instant) -> Double {
                let elapsed = start.duration(to: .now).components
                return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            }
            let restoreStart = ContinuousClock.now
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            await fixture.bridge.test_settleProjections()
            let restoreMS = milliseconds(since: restoreStart)
            XCTAssertLessThanOrEqual(restoreMS, 1000, "READY 300/3/5/10 restore budget")
            for intent in intents {
                XCTAssertEqual(fixture.bridge.test_launchEntryState(for: intent), .active)
            }
            let activeCount = await fixture.authority.snapshot().activeLinkCount
            XCTAssertEqual(activeCount, 10)
            XCTAssertLessThanOrEqual(fixture.host.projectionCount, 35, "At most two endpoints per activation plus one 15-endpoint full drain, never 300 chats per link")
            let restoreReads = fixture.host.candidateCallCount
            let restoreVisits = fixture.host.boundedCandidateVisits
            let restorePublications = fixture.host.projectionCount
            XCTAssertLessThanOrEqual(restoreReads, 5, "Only initial topology/discovery and final drain may enumerate")
            XCTAssertLessThanOrEqual(fixture.host.fullCandidateVisits, 5 * chatCount)
            XCTAssertLessThanOrEqual(restoreVisits, 500, "Per-link proof and membership work must not scale with unrelated chats")
            let subject = candidates[chatCount - 1]
            let expectedInputs = await fixture.authority.projectionInputs(forEndpoint: subject.domainEndpoint)
            let expectedMenu = AgentSidebarOversightMenuProjection.make(target: subject, inputs: expectedInputs, candidates: candidates)
            var refreshSamples: [Double] = []
            var menuSamples: [Double] = []
            for sample in 0 ... 20 {
                let reads = fixture.host.candidateCallCount
                let start = ContinuousClock.now
                await fixture.bridge.test_settleProjections()
                let refreshMS = milliseconds(since: start)
                XCTAssertEqual(fixture.host.candidateCallCount - reads, 2)
                let summaryReads = fixture.host.candidateCallCount
                XCTAssertEqual(fixture.bridge.sidebarOversightSummary(for: subject.domainEndpoint)?.availableObserverCount, 5)
                XCTAssertEqual(fixture.host.candidateCallCount, summaryReads, "Closed row must not enumerate candidates")
                let menuStart = ContinuousClock.now
                let menu = fixture.bridge.sidebarOversightMenu(for: subject.domainEndpoint)
                let menuMS = milliseconds(since: menuStart)
                XCTAssertEqual(menu, expectedMenu)
                XCTAssertEqual(fixture.host.candidateCallCount - summaryReads, 1)
                if sample > 0 { refreshSamples.append(refreshMS)
                    menuSamples.append(menuMS)
                }
            }
            let sparseReads = fixture.host.candidateCallCount
            await fixture.bridge.test_refreshStatus(sessionIDs: [candidates[0].sessionID])
            XCTAssertEqual(fixture.host.candidateCallCount, sparseReads, "Sparse status performs no full discovery")
            XCTAssertLessThanOrEqual(refreshSamples.sorted()[18], 50, "Warm full refresh nearest-rank p95 budget")
            XCTAssertLessThanOrEqual(menuSamples.sorted()[18], 50, "Open-time menu nearest-rank p95 budget")
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
            XCTAssertTrue(fixture.host.hydrationRequests.isEmpty)
            print("OVERSIGHT_SCALE chats=\(chatCount) windows=3 observers=5 links=10 restoreMS=\(restoreMS) restoreReads=\(restoreReads) restoreVisits=\(restoreVisits) publications=\(restorePublications) refreshMS=\(refreshSamples) menuMS=\(menuSamples)")
        }
    }

    func testDuplicateArrivingAfterClassificationStillRefusesUUIDRestore() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.host.beforeUUIDCensus = { fixture.host.candidates = [observer, target, duplicate] }
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.activationFailed))
    }

    func testBothExactHydrationProofsAreFreshAfterReservation() async throws {
        for driftObserver in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            defer { fixture.bridge.freezeForTermination() }
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            let drifting = driftObserver ? observer : target
            let binding = try XCTUnwrap(drifting.restorationReadiness.bindingToken)
            fixture.host.candidates = [observer, target]
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            fixture.bridge.test_afterReservationBeforeActivation = { _ in
                let current = self.withReadiness(drifting, .terminal(binding, .sourceRevisionSuperseded))
                fixture.host.candidates = driftObserver ? [current, target] : [observer, current]
            }
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            let snapshot = await fixture.authority.snapshot()
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(snapshot.activeLinkCount, 0)
            XCTAssertEqual(snapshot.pendingReservationCount, 0)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
            XCTAssertNotNil(token, "Transient exact proof drift must wait, not retire")
        }
    }

    func testDirtyPassRestartsDiscoveryBeforeReservingALaterPair() async throws {
        let candidates = (1 ... 4).map { makeReadyCandidate(windowID: $0, sessionID: UUID()) }
        let pairs = [0, 2].map {
            AgentSessionOversightIntent(observerSessionID: candidates[$0].sessionID, targetSessionID: candidates[$0 + 1].sessionID)
        }
        try JSONEncoder().encode(AgentSessionOversightIntentDocument(links: pairs)).write(
            to: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)
        )
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
        fixture.host.candidates = candidates
        fixture.host.descriptors = candidates.map { descriptor(for: $0) }
        let epoch = fixture.host.discovery[0].epoch
        fixture.bridge.test_afterReservationBeforeActivation = { _ in
            fixture.bridge.test_afterReservationBeforeActivation = nil
            fixture.host.discovery = [AgentSessionLinkDiscoveryState(epoch: epoch, isComplete: false)]
            fixture.bridge.noteTopologyMayHaveChanged()
        }
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1, "A dirty pass cannot spend the later pair's allowance")
        fixture.host.discovery = [AgentSessionLinkDiscoveryState(epoch: epoch, isComplete: true)]
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 2)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 2)
    }

    // MARK: - Same-process window reopen

    func testCapturedObserverTargetAndBothWindowClosesRestoreOneFreshManagedGrant() async throws {
        let closingWindows: [Set<Int>] = [[1], [2], [1, 2]]
        for windows in closingWindows {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let originalReference = await liveReference(fixture)
            let oldReference = try XCTUnwrap(originalReference)
            let originalToken = await fixture.store.token(for: pair)
            for windowID in windows {
                fixture.bridge.noteOversightWindowClosing(windowID: windowID)
            }
            replaceTopology(fixture, with: [observer, target].filter { !windows.contains($0.windowID) })
            for windowID in windows {
                await fixture.bridge.invalidateWindow(windowID, reason: .windowClosed)
            }
            await fixture.bridge.test_settleLaunchReconciliation()

            let parkedToken = await fixture.store.token(for: pair)
            let retiredGrant = await fixture.authority.activeGrant(for: oldReference)
            XCTAssertEqual(parkedToken, originalToken)
            XCTAssertNil(retiredGrant)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))

            let reopenedObserver = windows.contains(1)
                ? makeReadyCandidate(windowID: 3, sessionID: observerSessionID) : observer
            let reopenedTarget = windows.contains(2)
                ? makeReadyCandidate(windowID: 4, sessionID: targetSessionID) : target
            replaceTopology(fixture, with: [reopenedObserver, reopenedTarget])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, oldReference)
            let inventory = await fixture.authority.links(forObserverEndpoint: reopenedObserver.domainEndpoint)
            XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
            XCTAssertEqual(inventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let repeated = await liveReference(fixture)
            XCTAssertEqual(repeated, replacement, "An ordinary event must not reserve again.")
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    func testUnlinkAdmittedBeforeCloseRetiresItsParkedIntentAfterGrantRemoval() async throws {
        let (fixture, observer, target) = try await makeRestoredFixture()
        let original = await liveReference(fixture)
        let reference = try XCTUnwrap(original)
        let fence = TestReleaseFence(name: "Unlink admitted before close")
        fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
        let stop = Task { @MainActor in
            await fixture.bridge.stopMonitorLink(
                observerEndpoint: observer.domainEndpoint, targetEndpoint: target.domainEndpoint,
                expectedReference: reference
            )
        }
        await fence.waitUntilEntered()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()
        let retired = await fixture.authority.activeGrant(for: reference)
        let parkedToken = await fixture.store.token(for: pair)
        XCTAssertNil(retired)
        XCTAssertNotNil(parkedToken)
        fixture.bridge.test_afterStopAdmission = nil
        fence.release()
        let outcome = await stop.value
        XCTAssertNil(outcome.failureMessage)
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token, "An admitted Unlink must forget its exact parked ownership")
        replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    func testParkedDeletionCannotRestoreAndFailedCleanupRemainsRetryable() async throws {
        for failsWrite in [false, true] {
            AgentSessionDeletionRegistry.shared.test_reset()
            let (fixture, observer, _) = try await makeRestoredFixture()
            fixture.bridge.attach(host: fixture.host)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            fixture.gate.failsNextWrites = failsWrite
            let deletion = AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: targetSessionID)
            await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(deletion)
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry, failsWrite)
            fixture.gate.failsNextWrites = false
            await fixture.bridge.retryPendingIntentCleanup()
            let token = await fixture.store.token(for: pair)
            XCTAssertNil(token)
            XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        }
    }

    // MARK: - Barriers

    func testCreatorLaneRestoresAsOrdinaryManagedLinkWithoutStartingAProviderTask() async throws {
        try seedSavedPair()
        let originalFile = try Data(contentsOf: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename))
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lane = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, lane]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: lane)]
        fixture.host.laneCreatorByEndpoint[lane.domainEndpoint] = observerSessionID

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let inventory = await fixture.authority.links(forObserverEndpoint: observer.domainEndpoint)
        XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
        XCTAssertEqual(inventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
        XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)), originalFile)
    }

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

    func testSameWindowReopenRestoresAfterPassiveHydrationIsInterruptedByDiscoveryChange() async throws {
        for interrupted in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            let workspaceID = UUID()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID, workspaceID: workspaceID)
            let target = makeReadyCandidate(windowID: 1, sessionID: targetSessionID, workspaceID: workspaceID)
            replaceTopology(fixture, with: [observer, target])
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            let original = await liveReference(fixture)
            XCTAssertNotNil(original)
            let token = await fixture.store.token(for: pair)

            fixture.bridge.noteOversightWindowClosing(windowID: 1)
            replaceTopology(fixture, with: [])
            await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()

            let reopenedObserver = makeReadyCandidate(windowID: 2, sessionID: observerSessionID, workspaceID: workspaceID)
            let reopenedTarget = makeReadyCandidate(windowID: 2, sessionID: targetSessionID, workspaceID: workspaceID)
            fixture.host.candidates = [reopenedObserver]
            fixture.host.descriptors = [descriptor(for: reopenedObserver), descriptor(for: reopenedTarget)]
            let epoch = AgentSessionLinkDiscoveryEpoch(windowID: 2, workspaceID: workspaceID, generation: 1)
            fixture.host.discovery = [.init(epoch: epoch, isComplete: true)]

            // Gate the host's passive load, not a provider: delivery can be abandoned by its owner.
            let completeHydration = {
                fixture.host.candidates = [reopenedObserver, reopenedTarget]
                fixture.bridge.noteCandidateReadinessChanged()
            }
            var pendingHydration: (() -> Void)?
            fixture.host.hydrationHandler = { _ in pendingHydration = completeHydration }
            defer { fixture.host.hydrationHandler = nil }
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
            XCTAssertNotNil(pendingHydration)
            let beforeHydration = await fixture.authority.links(forObserver: observerSessionID)
            XCTAssertTrue(beforeHydration.items.isEmpty)

            if interrupted {
                // Model a workspace activation discarding that request. The saved bindings survive.
                let successor = AgentSessionLinkDiscoveryEpoch(windowID: 2, workspaceID: workspaceID, generation: 2)
                fixture.host.discovery = [.init(epoch: successor, isComplete: false)]
                pendingHydration = nil
                fixture.bridge.noteTopologyMayHaveChanged()
                await fixture.bridge.test_settleLaunchReconciliation()
                fixture.host.hydrationHandler = { _ in completeHydration() }
                fixture.host.discovery = [.init(epoch: successor, isComplete: true)]
                fixture.bridge.noteCandidateReadinessChanged()
            } else {
                pendingHydration?()
                pendingHydration = nil
            }
            await fixture.bridge.test_settleLaunchReconciliation()

            let restored = await fixture.authority.links(forObserverEndpoint: reopenedObserver.domainEndpoint)
            XCTAssertEqual(
                restored.items.map(\.targetSessionID), [targetSessionID],
                "Same-window reopen must restore without a user turn; interrupted=\(interrupted)."
            )
            if let link = restored.items.first {
                XCTAssertNotEqual(DomainAgentSessionLinkReference(linkID: link.linkID, generation: link.generation), original)
                XCTAssertEqual(link.capabilities, DomainAgentSessionLinkCapability.managed)
            }
            let retainedToken = await fixture.store.token(for: pair)
            XCTAssertEqual(retainedToken, token)
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    // MARK: - Lazy background tabs

    /// A saved session that is *present* but unhydrated is waited for — never declared missing — and
    /// passive loading is owned by the host, so the pair comes back without the user opening every
    /// endpoint's tab. The already-hydrated observer is never asked to reload.
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
        XCTAssertEqual(
            fixture.host.hydrationRequests,
            [[targetSessionID]],
            "Only the unhydrated endpoint of the saved pair is asked to load."
        )

        // A still-cold endpoint is requested again; the host loader owns in-flight deduplication.
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID], [targetSessionID]])

        // The requested load lands: the tab becomes a live authoritative candidate.
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        let restoredInventory = await fixture.authority.links(forObserverEndpoint: observer.domainEndpoint)
        XCTAssertEqual(restoredInventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
        let managedLease = try await fixture.authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer.domainEndpoint,
            targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(managedLease.capability, .manage, "restoration follows the same managed Add path")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    /// A bound-but-still-pending candidate (a tab whose session object exists but whose payload has
    /// not loaded) is also asked to load; an authoritative one is not.
    func testAPendingCandidateIsAskedToHydrateButAnAuthoritativeOneIsNot() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let ready = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(bindingToken, _) = ready.restorationReadiness else {
            return XCTFail("Expected an authoritative fixture")
        }
        let pending = withReadiness(ready, .pending(bindingToken))
        fixture.host.candidates = [observer, pending]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: pending)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
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
                .missingPayload
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

    /// A source revision can change while a passive background load is preparing. That does not
    /// prove the saved relationship is gone; a later authoritative save may safely restore it.
    func testSupersededHydrationKeepsIntentUntilAuthoritativeRecovery() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(bindingToken, _) = target.restorationReadiness else {
            return XCTFail("Expected an authoritative fixture")
        }
        fixture.host.candidates = [observer, withReadiness(target, .pending(bindingToken))]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])

        fixture.host.candidates = [
            observer,
            withReadiness(target, .terminal(bindingToken, .sourceRevisionSuperseded))
        ]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        var token = await fixture.store.token(for: pair)
        var restored = await isRestored(fixture)
        XCTAssertNotNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)

        fixture.host.candidates = [observer, withReadiness(target, .terminal(bindingToken, .loadFailed))]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A failed load may be transient and must not discard the intent.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let requestCount = fixture.host.hydrationRequests.count
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests.count, requestCount)

        fixture.host.candidates = [observer, target]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
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
        fixture.host.candidates = [observer, target]
        fixture.host.beforeUUIDCensus = {
            fixture.host.candidates = [observer, rehydrating]
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

    func testSupersessionDuringEstablishmentKeepsIntentWithoutGranting() async throws {
        for bothEndpoints in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            guard case let .authoritative(targetToken, _) = target.restorationReadiness,
                  case let .authoritative(observerToken, _) = observer.restorationReadiness
            else {
                return XCTFail("Expected authoritative fixtures")
            }
            let superseded = withReadiness(target, .terminal(targetToken, .sourceRevisionSuperseded))
            let currentObserver = bothEndpoints
                ? withReadiness(observer, .terminal(observerToken, .loadFailed)) : observer
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            // Classification sees completed payloads; the shared path sees their supersession.
            fixture.host.candidates = [observer, target]
            fixture.host.beforeUUIDCensus = {
                fixture.host.candidates = [currentObserver, superseded]
            }

            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()

            let restored = await isRestored(fixture)
            let token = await fixture.store.token(for: pair)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
            XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
            XCTAssertNotNil(token)
        }
    }

    func testTransientObserverFailureDoesNotMaskMissingTargetPayload() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(observerToken, _) = observer.restorationReadiness,
              case let .authoritative(targetToken, _) = target.restorationReadiness
        else {
            return XCTFail("Expected authoritative fixtures")
        }
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.host.candidates = [
            withReadiness(observer, .terminal(observerToken, .loadFailed)),
            withReadiness(target, .terminal(targetToken, .missingPayload))
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.hydrationFailed))
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
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
