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
        var preparedSessionRuntimes: (any PreparedAgentSessionRuntimeRegistry)?
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

        func check() throws {
            if failsNextWrites { throw CocoaError(.fileWriteOutOfSpace) }
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
        let binding = AgentPersistentSessionBindingIdentity(tabID: tabID, sessionID: sessionID)
        return AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: binding.generation,
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
                    bindingIdentity: binding,
                    bindingTransitionGeneration: 1
                ),
                .persistedPayloadApplied
            )
        )
    }

    /// The same live incarnation with a different hydration proof.
    ///
    /// The endpoint identity and legacy loaded flag stay unchanged. Readiness must still refuse
    /// an operation or restoration against a pending or terminal payload proof.
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
            beforeCommit: { try gate.check() }
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

    func testUnscopedLaunchIntentDoesNotConstructBackgroundRuntime() async throws {
        final class Registry: PreparedAgentSessionRuntimeRegistry {
            var preparations = 0
            func addingPreparedRuntimeCarriers(to snapshot: AgentSessionCarrierResolver.Snapshot, sessionIDs: Set<UUID>?, windowIDs: Set<Int>) -> AgentSessionCarrierResolver.Snapshot {
                snapshot
            }

            func hasPreparedRuntime(_ sessionID: UUID) -> Bool {
                false
            }

            func claimPreparedRuntimeVisit(_ sessionID: UUID) -> Bool {
                true
            }

            func finishPreparedRuntimeVisit(_ sessionID: UUID) {}
            func releasePreparedOversightOwnerForVisit(sessionID: UUID, preparingReplacement: Bool) async -> Bool {
                true
            }

            func queuePreparedRuntimeVisit(_ sessionID: UUID, resume: @escaping @MainActor () async -> Void) {}
            func beginPreparedOversightPreparation(_ id: UUID) {}
            func endPreparedOversightPreparation(_ id: UUID) {}
            func prepareScopedSavedTarget(_ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool) async -> Bool {
                preparations += 1
                return false
            }
        }
        try seedSavedPair()
        let fixture = makeFixture()
        let registry = Registry()
        fixture.host.preparedSessionRuntimes = registry
        fixture.host.candidates = [makeReadyCandidate(windowID: 1, sessionID: observerSessionID)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        let uncertain = await fixture.bridge.launchCoordinatorPrepareSavedTargets([pair])
        fixture.bridge.launchCoordinatorFinishSavedTargetPreparation()
        XCTAssertTrue(uncertain.isEmpty)
        XCTAssertEqual(registry.preparations, 0, "Ordinary unscoped links restore lazily, not as full background compositions")
    }

    func testSavedPreparationOwnershipSpansEstablishmentAndIsReleasedOnEarlyExit() async {
        // The real pass owns this bracket: releasing immediately after hydration lets asynchronous
        // owner cleanup win before the restored link's actor transaction can commit.
        final class PreparationDelegate: AgentSessionOversightLaunchCoordinatorDelegate {
            let launchCoordinatorHost: AgentSessionLinkEndpointHost?
            var launchCoordinatorIsFrozen = false
            var freezeDuringPreparation = false
            var events: [String] = []
            var ownsPreparation = false
            init(host: AgentSessionLinkEndpointHost) {
                launchCoordinatorHost = host
            }

            func launchCoordinatorPrepareSavedTargets(_: [AgentSessionOversightIntent]) async -> Set<UUID> {
                ownsPreparation = true
                events.append("prepare")
                launchCoordinatorIsFrozen = freezeDuringPreparation
                return []
            }

            func launchCoordinatorFinishSavedTargetPreparation() {
                XCTAssertTrue(ownsPreparation)
                ownsPreparation = false
                events.append("finish")
            }

            func launchCoordinatorEstablish(pair _: AgentSessionOversightIntent, token _: AgentSessionOversightIntentToken?, assertedAt _: UInt64?, proof _: AgentSessionOversightRestorationProof?) async -> AgentSessionLinkRuntimeBridge.EstablishmentResult {
                XCTAssertTrue(ownsPreparation, "An unlinked prepared owner must survive establishment's actor hops")
                events.append("establish")
                await Task.yield()
                XCTAssertTrue(ownsPreparation)
                return .init(outcome: .rejected(message: "controlled refusal"))
            }

            func launchCoordinatorRemoveIntent(pair _: AgentSessionOversightIntent, token _: AgentSessionOversightIntentToken, assertedAt _: UInt64?) async -> AgentSessionOversightIntentMutationReceipt {
                fatalError("No deletion in this fixture")
            }

            func launchCoordinatorRevoke(reference _: DomainAgentSessionLinkReference) async {
                XCTFail("No active grant")
            }

            func launchCoordinatorReportWarning(id _: String, message _: String) {}
            func launchCoordinatorClearWarning(id _: String) {}
            func launchCoordinatorRequestHydration(sessionIDs _: Set<UUID>) {
                XCTFail("Both endpoints are ready")
            }
        }
        for interrupted in [false, true] {
            let host = FakeHost()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            host.candidates = [observer, target]
            host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            host.discovery = [.init(epoch: .init(windowID: 1, workspaceID: observer.workspaceID, generation: 1), isComplete: true)]
            let delegate = PreparationDelegate(host: host)
            delegate.freezeDuringPreparation = interrupted
            let coordinator = AgentSessionOversightLaunchCoordinator(delegate: delegate)
            let token = AgentSessionOversightIntentToken(storeProcessGeneration: UUID(), pair: pair, pairRevision: 1)
            coordinator.loadLaunchEntries(.init(source: .loaded, storeRevision: 1, tokenByPair: [pair: token]), automaticRestoreEnabled: true)
            coordinator.updateTopologyState(.completeAllEntriesConsumed)
            await coordinator.settle()
            XCTAssertEqual(delegate.events, interrupted ? ["prepare", "finish"] : ["prepare", "establish", "finish"])
            XCTAssertFalse(delegate.ownsPreparation)
            coordinator.freeze()
        }
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
        // The refusal itself proves nothing and does not immediately re-run.
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        // The next readiness event reclassifies first and waits for the duplicate to clear.
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
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

    func testDelegatedUnlinkRechecksAuthorityInsideOwningPairLane() async throws {
        let (fixture, _, _) = try await makeRestoredFixture()
        let original = await liveReference(fixture)
        let reference = try XCTUnwrap(original)
        let originalToken = await fixture.store.token(for: pair)
        let fence = TestReleaseFence(name: "Delegated unlink after admission")
        var authorized = true
        fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
        let stop = Task { @MainActor in
            await fixture.bridge.stopMonitorLink(
                observerSessionID: self.observerSessionID, targetSessionID: self.targetSessionID,
                linkID: reference.linkID, generation: reference.generation,
                isStillAuthorized: { authorized }
            )
        }
        await fence.waitUntilEntered()
        authorized = false
        fixture.bridge.test_afterStopAdmission = nil
        fence.release()
        let outcome = await stop.value
        XCTAssertNotNil(outcome.failureMessage)
        let remainingToken = await fixture.store.token(for: pair)
        let remainingGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertEqual(remainingToken, originalToken, "expired authority must not remove the durable intent")
        XCTAssertNotNil(remainingGrant, "the uncommitted Stop must not retire the live grant")
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
        let base = try XCTUnwrap(directory)
        defer { directory = base }
        for failsWrite in [false, true] {
            // Each variant is a separate profile. Reusing a terminal pair would correctly refuse
            // resurrection from the stale legacy seed and would not test cleanup failure.
            directory = base.appendingPathComponent("case-\(failsWrite)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            AgentSessionDeletionRegistry.shared.test_reset()
            let (fixture, observer, _) = try await makeRestoredFixture()
            fixture.bridge.attach(host: fixture.host)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            fixture.gate.failsNextWrites = failsWrite
            let deletion = try AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: targetSessionID)
            await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(deletion)
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertFalse(restored)
            await fixture.store.serializationBarrier()
            let saving = await fixture.store.saveState
            XCTAssertEqual(saving, failsWrite ? "failed" : "saved")
            fixture.gate.failsNextWrites = false
            await fixture.store.retrySaving()
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
        let attempt = try AgentSessionDeletionRegistry.shared
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

    func testCommittedDeletionReportsRemovalRatherThanRetainedIntent() async throws {
        try seedSavedPair()
        let deletion = try AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: targetSessionID)
        await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(deletion)
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
        replaceTopology(fixture, with: [makeReadyCandidate(windowID: 1, sessionID: observerSessionID)])
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.deleted))
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.first {
                $0.id == AgentSessionOversightWarningID.deletedRestoration
            }?.message,
            "Saved oversight links for deleted sessions were removed."
        )
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
            $0.id == AgentSessionOversightWarningID.terminalRestoration
        })
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.missing))
    }

    /// A never-granted duplicate waits, then restores through ordinary readiness and authorization.
    func testADuplicateLiveIncarnationRestoresWhenUniqueAgain() async throws {
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        var restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.first {
                $0.id == AgentSessionOversightWarningID.duplicateWaiting
            }?.message,
            "Some saved oversight links are waiting because a session is open in more than one window. Close the extra window to let RepoPrompt reconsider restoration."
        )

        // Closing the extra window is sufficient; no store reload or interactive Add is needed.
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
        // WindowStatesManager separately publishes topology after unregistering the window.
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        let retainedToken = await fixture.store.token(for: pair)
        XCTAssertEqual(retainedToken, token)
        XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
            $0.id == AgentSessionOversightWarningID.duplicateWaiting
        })
    }

    func testDuplicateNoticeHandlesDormantAndTransientDiscoveryBarriers() async throws {
        let base = try XCTUnwrap(directory)
        defer { directory = base }
        for incompleteDiscovery in [false, true] {
            directory = base.appendingPathComponent("incomplete-discovery-\(incompleteDiscovery)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try seedSavedPair()
            let fixture = makeFixture()
            defer { fixture.bridge.freezeForTermination() }
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
            replaceTopology(fixture, with: [observer, target, duplicate])
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertTrue(fixture.bridge.currentPersistencePresentation.warnings.contains {
                $0.id == AgentSessionOversightWarningID.duplicateWaiting
            })

            let previousDiscovery = fixture.host.discovery
            if incompleteDiscovery {
                fixture.host.discovery = []
            } else {
                fixture.host.topology = .dormantAutoRestoreDisabled
            }
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            replaceTopology(fixture, with: [observer, target])
            await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()

            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
            XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
            if incompleteDiscovery {
                XCTAssertTrue(fixture.bridge.currentPersistencePresentation.warnings.contains {
                    $0.id == AgentSessionOversightWarningID.duplicateWaiting
                }, "Transient discovery retains the last completed census until its successor arrives.")
                fixture.host.discovery = previousDiscovery
                fixture.bridge.noteTopologyMayHaveChanged()
                await fixture.bridge.test_settleLaunchReconciliation()
            }
            XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
                $0.id == AgentSessionOversightWarningID.duplicateWaiting
            })
        }
    }

    func testDismissedDuplicateNoticeStaysDismissedUntilConditionReturns() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
        replaceTopology(fixture, with: [
            makeReadyCandidate(windowID: 1, sessionID: observerSessionID),
            makeReadyCandidate(windowID: 2, sessionID: targetSessionID),
            makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        ])
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.warnings.contains {
            $0.id == AgentSessionOversightWarningID.duplicateWaiting
        })
        fixture.bridge.dismissPersistenceWarnings(ids: [AgentSessionOversightWarningID.duplicateWaiting])
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
            $0.id == AgentSessionOversightWarningID.duplicateWaiting
        })

        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
            $0.id == AgentSessionOversightWarningID.duplicateWaiting
        }, "Readiness events must not undo the user's Dismiss action.")

        fixture.host.topology = .dormantAutoRestoreDisabled
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        fixture.host.topology = .completeAllEntriesConsumed
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.currentPersistencePresentation.warnings.count(where: {
            $0.id == AgentSessionOversightWarningID.duplicateWaiting
        }), 1)
    }

    func testDuplicateNoticeDoesNotFlickerAcrossTransientDiscovery() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
        replaceTopology(fixture, with: [
            makeReadyCandidate(windowID: 1, sessionID: observerSessionID),
            makeReadyCandidate(windowID: 2, sessionID: targetSessionID),
            makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        ])
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        fixture.bridge.reportPersistenceWarning(id: "test.warning", message: "Controlled warning")
        let expectedIDs = fixture.bridge.currentPersistencePresentation.warnings.map(\.id)
        XCTAssertTrue(expectedIDs.contains(AgentSessionOversightWarningID.duplicateWaiting))
        let firstPublication = fixture.host.publishedPresentations.count
        let previousDiscovery = fixture.host.discovery

        fixture.host.discovery = []
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        fixture.host.discovery = previousDiscovery
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.currentPersistencePresentation.warnings.map(\.id), expectedIDs)
        XCTAssertTrue(fixture.host.publishedPresentations.dropFirst(firstPublication).allSatisfy {
            $0.warnings.map(\.id) == expectedIDs
        }, "Transient discovery must neither remove/re-add the notice nor reorder warnings.")
    }

    func testClosingEveryDuplicateCopyEndsTheNeverGrantedEntry() async throws {
        let base = try XCTUnwrap(directory)
        defer { directory = base }
        for duplicateObserver in [false, true] {
            directory = base.appendingPathComponent("duplicate-observer-\(duplicateObserver)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try seedSavedPair()
            let fixture = makeFixture()
            defer { fixture.bridge.freezeForTermination() }
            fixture.host.topology = .incompleteLeftoversAbandoned(count: 2)
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            let duplicate = makeReadyCandidate(
                windowID: 3, sessionID: duplicateObserver ? observerSessionID : targetSessionID
            )
            replaceTopology(fixture, with: [observer, target, duplicate])
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)

            replaceTopology(fixture, with: [duplicateObserver ? target : observer])
            await fixture.bridge.invalidateWindow(duplicateObserver ? 1 : 2, reason: .windowClosed)
            await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.bindingDrift))
            XCTAssertFalse(fixture.bridge.currentPersistencePresentation.warnings.contains {
                $0.id == AgentSessionOversightWarningID.duplicateWaiting
            })
            let token = await fixture.store.token(for: pair)
            XCTAssertNotNil(token)

            replaceTopology(fixture, with: [observer, target])
            fixture.bridge.noteCandidateReadinessChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
        }
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
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

        var restored = await isRestored(fixture)
        XCTAssertFalse(restored, "An unproven incarnation must never be reauthorized.")
        // Restart survival: a target that rehydrates in place is routine at launch. The refusal
        // grants nothing, but it must not erase the user's saved relationship.
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A refused automatic restore must keep the durable intent.")

        // Once the target is authoritative again, the bounded retry restores the link.
        fixture.host.beforeUUIDCensus = nil
        fixture.host.candidates = [observer, target]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        restored = await isRestored(fixture)
        XCTAssertTrue(restored, "The saved link must restore after the transient refusal settles.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        fixture.bridge.freezeForTermination()
    }

    /// A launch entry that keeps getting refused stops retrying after its per-launch budget, but the
    /// intent stays durable for the next launch instead of being deleted.
    func testRepeatedlyRefusedRestoreExhaustsBudgetAndKeepsIntent() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        defer { fixture.bridge.freezeForTermination() }
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
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.host.candidates = [observer, target]
        // Every establishment observes drift, then the endpoint reports ready again.
        fixture.host.beforeUUIDCensus = {
            fixture.host.candidates = [observer, rehydrating]
        }

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(
            fixture.bridge.test_launchRefusedEstablishmentCount(for: pair), 1,
            "A refusal never retries back-to-back; it waits for the next readiness event."
        )
        for _ in 0 ..< AgentSessionOversightLaunchCoordinator.maxAutomaticEstablishmentAttempts + 2 {
            fixture.host.candidates = [observer, target]
            fixture.bridge.noteCandidateReadinessChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
        }

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.test_launchRefusedEstablishmentCount(for: pair),
            AgentSessionOversightLaunchCoordinator.maxAutomaticEstablishmentAttempts,
            "Retries are bounded per launch."
        )
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "Budget exhaustion must preserve the intent for the next launch.")

        // A new target incarnation is new evidence: the exhausted entry is not locked out for the
        // rest of the launch, and restores once establishment succeeds.
        fixture.host.beforeUUIDCensus = nil
        let reopened = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, reopened]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: reopened)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let recovered = await isRestored(fixture)
        XCTAssertTrue(recovered, "A changed endpoint earns a fresh retry budget.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
    }

    func testSupersessionDuringEstablishmentKeepsIntentWithoutGranting() async throws {
        for (supersedeObserver, supersedeTarget) in [(false, true), (true, false), (true, true)] {
            try seedSavedPair()
            let fixture = makeFixture()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            guard case let .authoritative(targetToken, _) = target.restorationReadiness,
                  case let .authoritative(observerToken, _) = observer.restorationReadiness
            else {
                return XCTFail("Expected authoritative fixtures")
            }
            let currentTarget = supersedeTarget
                ? withReadiness(target, .terminal(targetToken, .sourceRevisionSuperseded)) : target
            let currentObserver = supersedeObserver
                ? withReadiness(observer, .terminal(observerToken, .loadFailed)) : observer
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            // Classification sees completed payloads; the shared path sees their supersession.
            fixture.host.candidates = [observer, target]
            fixture.host.beforeUUIDCensus = {
                fixture.host.candidates = [currentObserver, currentTarget]
            }

            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()

            let restored = await isRestored(fixture)
            let token = await fixture.store.token(for: pair)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
            // The refusal spent one bounded retry and rearmed the entry for the next readiness event.
            XCTAssertEqual(fixture.bridge.test_launchRefusedEstablishmentCount(for: pair), 1)
            XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
        XCTAssertEqual(
            fixture.bridge.test_launchReservationStartCount(),
            1,
            "An audited entry is finished, never requeued."
        )
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.first {
                $0.id == AgentSessionOversightWarningID.terminalRestoration
            }?.message,
            "Some saved oversight links couldn’t be restored. They were kept for a later launch."
        )
        replaceTopology(fixture, with: [observer, target])
        await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
        // WindowStatesManager separately publishes topology after unregistering the window.
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        restored = await isRestored(fixture)
        XCTAssertFalse(restored, "A previously granted and revoked link must not be resurrected.")
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
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
        XCTAssertNotNil(token, "Launch retirement keeps the intent dormant; only a committed deletion removes it.")
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

    // MARK: - Dormant rows (no data loss)

    // Failed launch cleanup and Retry saving remain covered for committed deletions by
    // `testParkedDeletionCannotRestoreAndFailedCleanupRemainsRetryable`. Every other launch-terminal
    // reason keeps the saved row, so it owes no cleanup at all.

    func testAMissingTargetKeepsTheRowAndOwesNoCleanup() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        // Only the observer is present, under a topology that proves absence: the entry ends for this
        // launch, but the saved relationship is kept dormant even while writes fail.
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true

        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A missing endpoint is not proof of deletion; the row stays dormant.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.missing))
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        fixture.gate.failsNextWrites = false
        await fixture.bridge.retryPendingIntentCleanup()
        let afterRetry = await fixture.store.token(for: pair)
        XCTAssertNotNil(afterRetry, "Retry saving has nothing to remove")
    }

    /// The target comes back and the user explicitly re-adds the pair while Retry saving runs: the
    /// user ends up with a live grant backed by the durable row.
    func testExplicitAddOverADormantRowLeavesThePairGrantedAndDurable() async throws {
        let (fixture, _, _) = try await seedDormantRowWithTargetBack()

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
        XCTAssertNotNil(token, "Nothing may delete what the user just recreated.")
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored, "The grant and the durable row must agree.")
    }

    /// A delegated Add whose scope authority ends after the insert fails, but never removes a row
    /// that predates it.
    func testRevokedDelegatedAddOverADormantRowKeepsTheRow() async throws {
        let (fixture, observer, target) = try await seedDormantRowWithTargetBack()
        var authorized = true
        let pair = pair
        fixture.bridge.test_afterReservationBeforeActivation = { pendingPair in
            guard pendingPair == pair else { return }
            authorized = false
        }

        let outcome = await fixture.bridge.addDelegatedMonitorLink(
            observerEndpoint: observer.domainEndpoint,
            targetEndpoint: target.domainEndpoint,
            authorization: AgentSessionLinkDelegatedAddAuthorization(isCurrent: { authorized })
        )

        XCTAssertNotNil(outcome.failureMessage, "a revoked delegated Add must not report success: \(outcome)")
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A pre-existing row is never compensated away")
    }

    /// Control: with live authority the same delegated Add establishes over the dormant row.
    func testLiveDelegatedAddOverADormantRowEstablishes() async throws {
        let (fixture, observer, target) = try await seedDormantRowWithTargetBack()

        let outcome = await fixture.bridge.addDelegatedMonitorLink(
            observerEndpoint: observer.domainEndpoint,
            targetEndpoint: target.domainEndpoint,
            authorization: AgentSessionLinkDelegatedAddAuthorization(isCurrent: { true })
        )

        guard case .added = outcome else { return XCTFail("Expected the delegated Add to succeed, got \(outcome)") }
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token)
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
    }

    /// A saved pair whose launch entry ended because the target was missing, with the target back and
    /// writes working. The row is still on disk and nothing is owed.
    private func seedDormantRowWithTargetBack() async throws -> (
        Fixture, AgentSessionLinkEndpointCandidate, AgentSessionLinkEndpointCandidate
    ) {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        let dormant = await fixture.store.token(for: pair)
        XCTAssertNotNil(dormant)
        fixture.gate.failsNextWrites = false
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        return (fixture, observer, target)
    }
}
