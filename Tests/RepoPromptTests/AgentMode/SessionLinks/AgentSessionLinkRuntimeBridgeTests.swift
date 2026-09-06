import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Cross-window lifecycle bridge: synchronous first-link seeding, activation-time observation
/// ownership, serialized publication, and eager plus lazy revocation.
///
/// The bridge talks to the real `DomainAgentSessionLinkAuthority` through a fake endpoint host, so
/// two-window add/revoke/status flows are deterministic without constructing windows.
@MainActor
final class AgentSessionLinkRuntimeBridgeTests: XCTestCase {
    // MARK: - Fake host

    private final class FakeEndpointHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        var snapshotOverrides: [UUID: DomainAgentSessionObservationSnapshot] = [:]
        var installCountsBySession: [UUID: Int] = [:]
        var liveObservations: [UUID: () -> Void] = [:]
        var waitingOnByEndpoint: [DomainAgentSessionLinkEndpointIdentity: DomainAgentSessionWaitingOn] = [:]
        /// Per-observer saved Auto-wake selections, so a test can prove which session's set a write
        /// actually read and replaced.
        var autoWakeTargetsByEndpoint: [DomainAgentSessionLinkEndpointIdentity: Set<UUID>] = [:]
        var publishedProps: [UUID: AgentMonitorPillProps] = [:]
        var publishedPromptInventories: [UUID: AgentSessionLinkPromptInventory] = [:]
        var transcriptPages: [UUID: AgentSessionLinkTranscriptPage] = [:]
        /// Recorded reader identity for the most recent read, so a test can prove the observer's own
        /// session ID reaches the sanitizer rather than being dropped at the host boundary.
        var lastTranscriptReaderSessionID: UUID?
        /// Runs *inside* the transcript materialization, standing in for the real host's off-actor
        /// canonical projection. It is the suspension point a user's Stop can land in, so a test can
        /// revoke exactly where the read's post-await release gate has to arbitrate.
        var duringTranscriptPage: (() async -> Void)?
        /// Outcome the fake send transaction returns, plus the requests it observed.
        var sendOutcome: AgentSessionLinkSendTransactionOutcome = .blocked(.targetNotIdle)
        var sendRequests: [(candidate: AgentSessionLinkEndpointCandidate, request: AgentSessionLinkSendRequest)] = []
        var sendCommitOutcomes: [AgentSessionLinkSendCommitOutcome] = []
        /// Every liveness answer the transaction was handed, in order.
        var sendLivenessReadings: [AgentSessionLinkSendLiveness] = []
        /// Overrides the target window's teardown state without removing its candidate.
        var targetWindowIsClosing = false
        /// When true the fake invokes the commit fence exactly as the real host does.
        var invokesSendCommit = true
        /// Runs after the reservation exists but before the commit fence, so a test can land a
        /// revocation exactly in the window the fence is designed to arbitrate.
        var beforeSendCommit: (() async -> Void)?
        /// Runs immediately after the commit fence returned, which is the only window in which a
        /// queued entry is past its cancellation cutoff but has not settled yet.
        var afterSendCommit: (() async -> Void)?
        /// Per-session call counts, so a test can prove which projection path the UI actually uses.
        var observationSnapshotCalls: [UUID: Int] = [:]
        var statusProjectionCalls: [UUID: Int] = [:]
        var failObservationInstall = false
        /// Invoked on every candidate read so a test can simulate drift between reads.
        var onCandidatesRead: ((Int) -> Void)?
        private(set) var candidateReadCount = 0

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            candidateReadCount += 1
            onCandidatesRead?(candidateReadCount)
            return candidates
        }

        func agentSessionLinkObservationSnapshot(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> DomainAgentSessionObservationSnapshot {
            observationSnapshotCalls[candidate.sessionID, default: 0] += 1
            return snapshotOverrides[candidate.sessionID] ?? DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                idleForSend: true,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: "seeded",
                visibleRowCount: 2,
                lastActivityAt: Date(timeIntervalSince1970: 100)
            )
        }

        func agentSessionLinkSetWaitingOn(
            _ waitingOn: DomainAgentSessionWaitingOn?,
            for endpoint: DomainAgentSessionLinkEndpointIdentity
        ) -> Bool {
            guard candidates.contains(where: { $0.domainEndpoint == endpoint }) else { return false }
            waitingOnByEndpoint[endpoint] = waitingOn
            return true
        }

        func agentSessionLinkAutoWakeTargetSessionIDs(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> Set<UUID> {
            autoWakeTargetsByEndpoint[candidate.domainEndpoint] ?? []
        }

        func agentSessionLinkSetAutoWakeTargetSessionIDs(
            _ targetSessionIDs: Set<UUID>,
            for endpoint: DomainAgentSessionLinkEndpointIdentity
        ) -> Bool {
            guard candidates.contains(where: { $0.domainEndpoint == endpoint }) else { return false }
            autoWakeTargetsByEndpoint[endpoint] = targetSessionIDs
            return true
        }

        func agentSessionLinkStatusProjection(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> AgentSessionLinkStatusProjection? {
            statusProjectionCalls[candidate.sessionID, default: 0] += 1
            let snapshot = snapshotOverrides[candidate.sessionID]
            return AgentSessionLinkStatusProjection(
                status: snapshot?.status ?? .idle,
                pendingInteractionKind: snapshot?.pendingInteractionKind,
                lastActivityAt: snapshot?.lastActivityAt ?? Date(timeIntervalSince1970: 100)
            )
        }

        /// Runs inside the observation install, which `addMonitorLink` performs after `activateLink`
        /// has made the grant live and before the projection refresh republishes — a point strictly
        /// inside the window a concurrently dispatching provider turn composes its supplement in.
        var duringObservationInstall: ((FakeEndpointHost) -> Void)?

        func agentSessionLinkInstallObservation(
            for candidate: AgentSessionLinkEndpointCandidate,
            onChange: @escaping @MainActor () -> Void
        ) -> AgentSessionLinkObservationToken? {
            duringObservationInstall?(self)
            guard !failObservationInstall else { return nil }
            let sessionID = candidate.sessionID
            installCountsBySession[sessionID, default: 0] += 1
            liveObservations[sessionID] = onChange
            return AgentSessionLinkObservationToken { [weak self] in
                self?.liveObservations.removeValue(forKey: sessionID)
            }
        }

        /// Keyed by exact endpoint, so a test can prove a publication reached the granted
        /// incarnation rather than merely some session carrying the same UUID.
        var publishedPropsByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentMonitorPillProps] = [:]
        var publishedInventoriesByEndpoint:
            [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPromptInventory] = [:]

        func agentSessionLinkPublishProjection(
            _ props: AgentMonitorPillProps,
            to endpoint: DomainAgentSessionLinkEndpointIdentity
        ) {
            publishedPropsByEndpoint[endpoint] = props
            publishedProps[endpoint.sessionID] = props
        }

        func agentSessionLinkPublishPromptInventory(
            _ inventory: AgentSessionLinkPromptInventory,
            to endpoint: DomainAgentSessionLinkEndpointIdentity
        ) {
            guard promptInventoryHoldsByEndpoint[endpoint] == nil else { return }
            publishedInventoriesByEndpoint[endpoint] = inventory
            publishedPromptInventories[endpoint.sessionID] = inventory
        }

        /// Passive queues recorded per exact endpoint, with a publication counter: a test has to be
        /// able to prove not only *what* was published but that a presentation-only repaint published
        /// nothing at all.
        var publishedPassiveNoticesByEndpoint:
            [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPassiveStatusNotices.Snapshot] = [:]
        private(set) var passiveNoticePublicationCount = 0

        func agentSessionLinkPublishPassiveStatusNotices(
            _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
            to endpoint: DomainAgentSessionLinkEndpointIdentity
        ) {
            passiveNoticePublicationCount += 1
            publishedPassiveNoticesByEndpoint[endpoint] = snapshot
        }

        /// Mirrors the real store's fence, because the bridge's contract is that a publication
        /// landing inside a withheld window is refused rather than merely overwritten later.
        var promptInventoryHoldsByEndpoint: [DomainAgentSessionLinkEndpointIdentity: UInt64] = [:]
        var retractedInventoriesByEndpoint:
            [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPromptInventory] = [:]
        private var nextPromptInventoryHoldToken: UInt64 = 0

        func agentSessionLinkWithholdPromptInventory(
            for endpoint: DomainAgentSessionLinkEndpointIdentity
        ) -> UInt64? {
            nextPromptInventoryHoldToken += 1
            promptInventoryHoldsByEndpoint[endpoint] = nextPromptInventoryHoldToken
            if let inventory = publishedInventoriesByEndpoint[endpoint] {
                retractedInventoriesByEndpoint[endpoint] = inventory
                publishedInventoriesByEndpoint.removeValue(forKey: endpoint)
                publishedPromptInventories.removeValue(forKey: endpoint.sessionID)
            }
            return nextPromptInventoryHoldToken
        }

        func agentSessionLinkReleasePromptInventoryHold(
            _ token: UInt64?,
            for endpoint: DomainAgentSessionLinkEndpointIdentity,
            publishing inventory: AgentSessionLinkPromptInventory?
        ) {
            guard let token else { return }
            let ownsFence = promptInventoryHoldsByEndpoint[endpoint] == token
            if ownsFence { promptInventoryHoldsByEndpoint.removeValue(forKey: endpoint) }
            guard let value = inventory
                ?? (ownsFence ? retractedInventoriesByEndpoint[endpoint] : nil)
            else {
                return
            }
            publishedInventoriesByEndpoint[endpoint] = value
            publishedPromptInventories[endpoint.sessionID] = value
        }

        func agentSessionLinkTranscriptPage(
            for candidate: AgentSessionLinkEndpointCandidate,
            anchor: AgentSessionLinkTranscriptAnchor?,
            direction: AgentSessionLinkReadDirectionInput,
            maxItems: Int,
            maxOutputBytes: Int,
            readerSessionID: UUID?
        ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
            lastTranscriptReaderSessionID = readerSessionID
            await duringTranscriptPage?()
            return transcriptPages[candidate.sessionID].map { .success($0) } ?? .failure(.targetLoading)
        }

        func agentSessionLinkSendLiveness(
            observer: DomainAgentSessionLinkEndpointIdentity,
            target: DomainAgentSessionLinkEndpointIdentity
        ) -> AgentSessionLinkSendLiveness {
            let live = candidates.map(\.domainEndpoint)
            return AgentSessionLinkSendLiveness(
                observerEndpointIsLive: live.contains(observer),
                targetEndpointIsLive: live.contains(target),
                targetWindowIsClosing: targetWindowIsClosing
            )
        }

        func agentSessionLinkPerformSend(
            to candidate: AgentSessionLinkEndpointCandidate,
            request: AgentSessionLinkSendRequest,
            liveness: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            sendRequests.append((candidate, request))
            sendLivenessReadings.append(liveness())
            await beforeSendCommit?()
            if invokesSendCommit {
                let commit = await commitAuthorization()
                sendCommitOutcomes.append(commit)
                await afterSendCommit?()
                guard commit == .committed else {
                    return .blocked(commit == .shuttingDown ? .shuttingDown : .linkRevoked)
                }
            }
            return sendOutcome
        }

        /// Every snooze call the bridge actually admitted, so a test can prove a denial never reached
        /// the owning session at all rather than being refused once it got there.
        var snoozeProjectionCalls: [(
            endpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            reference: DomainAgentSessionLinkReference
        )] = []
        var snoozeMutationCalls: [(
            endpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            reference: DomainAgentSessionLinkReference,
            command: AgentSessionLinkAutoWakeSnoozeCommand,
            origin: AgentSessionLinkAutoWakeSnoozeOrigin
        )] = []
        var snoozeProjectionResult:
            Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> =
            .success(nil)
        var snoozeMutationResult:
            Result<
                AgentSessionLinkAutoWakeSnoozeMutationOutcome,
                AgentSessionLinkAutoWakeSnoozeFailure
            > = .success(AgentSessionLinkAutoWakeSnoozeMutationOutcome(
                change: .snoozed,
                projection: nil,
                currentDispatchAlreadyStarted: false
            ))

        func agentSessionLinkAutoWakeSnoozeProjection(
            for endpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            expectedReference: DomainAgentSessionLinkReference
        ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
            snoozeProjectionCalls.append((endpoint, targetSessionID, expectedReference))
            return snoozeProjectionResult
        }

        func agentSessionLinkMutateAutoWakeSnooze(
            for endpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            expectedReference: DomainAgentSessionLinkReference,
            command: AgentSessionLinkAutoWakeSnoozeCommand,
            origin: AgentSessionLinkAutoWakeSnoozeOrigin
        ) -> Result<
            AgentSessionLinkAutoWakeSnoozeMutationOutcome,
            AgentSessionLinkAutoWakeSnoozeFailure
        > {
            snoozeMutationCalls.append((endpoint, targetSessionID, expectedReference, command, origin))
            return snoozeMutationResult
        }

        func fireObservation(for sessionID: UUID) {
            liveObservations[sessionID]?()
        }
    }

    // MARK: - Tool advertisement recorder

    /// Records every session the bridge asks to re-advertise `agent_session_link` for.
    ///
    /// An actor because the bridge's invalidator is `@Sendable` and is awaited off the test's
    /// MainActor context. Order is preserved so a test can assert *which* endpoint was invalidated
    /// and in what sequence, not merely how many invalidations happened.
    private actor ToolAdvertisementRecorder {
        private(set) var invalidatedSessionIDs: [UUID] = []

        func record(_ sessionID: UUID) {
            invalidatedSessionIDs.append(sessionID)
        }

        func count() -> Int {
            invalidatedSessionIDs.count
        }

        func count(of sessionID: UUID) -> Int {
            invalidatedSessionIDs.count(where: { $0 == sessionID })
        }

        func drain() -> [UUID] {
            defer { invalidatedSessionIDs = [] }
            return invalidatedSessionIDs
        }
    }

    // MARK: - Fixtures

    private func makeAuthority() -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func makeCandidate(
        windowID: Int,
        sessionID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        tabID: UUID = UUID(),
        persistentBindingGeneration: UUID? = UUID(),
        bindingTransitionGeneration: UInt64 = 1,
        hasLoadedPersistedState: Bool = true,
        bindingTransitionInProgress: Bool = false,
        isTopLevel: Bool = true,
        isClosing: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        roleAllowsOutboundMonitoring: Bool = true,
        displayName: String = "Session",
        providerDisplayName: String? = "Codex CLI",
        locationLabel: String? = "worktree/main",
        isDeletionInProgress: Bool = false
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration,
            isTopLevel: isTopLevel,
            hasLoadedPersistedState: hasLoadedPersistedState,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            roleAllowsOutboundMonitoring: roleAllowsOutboundMonitoring,
            displayName: displayName,
            providerDisplayName: providerDisplayName,
            locationLabel: locationLabel,
            isDeletionInProgress: isDeletionInProgress
        )
    }

    private struct Fixture {
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeEndpointHost
        let bridge: AgentSessionLinkRuntimeBridge
        let observer: AgentSessionLinkEndpointCandidate
        let target: AgentSessionLinkEndpointCandidate
        let advertisement: ToolAdvertisementRecorder
    }

    private func makeFixture() -> Fixture {
        let authority = makeAuthority()
        let host = FakeEndpointHost()
        let observer = makeCandidate(windowID: 1, displayName: "Planning")
        let target = makeCandidate(windowID: 2, displayName: "Build API")
        host.candidates = [observer, target]
        let advertisement = ToolAdvertisementRecorder()
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { sessionID in
                await advertisement.record(sessionID)
            },
            now: { Date(timeIntervalSince1970: 1000) }
        )
        return Fixture(
            authority: authority,
            host: host,
            bridge: bridge,
            observer: observer,
            target: target,
            advertisement: advertisement
        )
    }

    private func addLink(_ fixture: Fixture) async -> AgentMonitorAddOutcome {
        await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
    }

    /// Reads the live link reference from the authority rather than assuming generation numbering.
    private func linkReference(
        _ fixture: Fixture,
        observer: UUID? = nil,
        target: UUID? = nil
    ) async -> DomainAgentSessionLinkReference? {
        let inventory = await fixture.authority.links(forObserver: observer ?? fixture.observer.sessionID)
        guard let item = inventory.items.first(where: {
            $0.targetSessionID == (target ?? fixture.target.sessionID)
        }) else { return nil }
        return DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
    }

    private func pollState(
        _ fixture: Fixture,
        observer: AgentSessionLinkEndpointCandidate? = nil,
        target: UUID? = nil
    ) async -> DomainAgentSessionLinkTargetState? {
        let lease = await fixture.authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: (observer ?? fixture.observer).domainEndpoint,
            targetSessionID: target ?? fixture.target.sessionID
        )
        guard case let .success(lease) = lease else { return nil }
        return await fixture.authority.targetState(for: lease)
    }

    /// The observer's first outbound row as the dashboard would render it.
    private func outboundRow(
        _ fixture: Fixture,
        observer: UUID? = nil
    ) -> AgentMonitorPillProps.Outbound? {
        fixture.host.publishedProps[observer ?? fixture.observer.sessionID]?.outbound.first
    }

    /// Delivers one target observation and drains both refresh paths, so assertions read settled
    /// rows rather than whichever repaint happened to be requested.
    private func publishTargetActivity(
        _ fixture: Fixture,
        status: DomainAgentSessionLinkStatus,
        activity: TimeInterval
    ) async {
        await publishActivity(fixture, for: fixture.target, status: status, activity: activity)
    }

    /// The same delivery for any overseen target, so a multi-target queue can be driven one target at
    /// a time.
    private func publishActivity(
        _ fixture: Fixture,
        for target: AgentSessionLinkEndpointCandidate,
        status: DomainAgentSessionLinkStatus,
        activity: TimeInterval
    ) async {
        fixture.host.snapshotOverrides[target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: target.sessionID,
            displayName: target.displayName,
            providerDisplayName: "Codex CLI",
            status: status,
            idleForSend: status == .idle,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: activity)
        )
        fixture.host.fireObservation(for: target.sessionID)
        await fixture.bridge.test_settleProjections()
        await fixture.bridge.test_settleMonitorProjectionRefresh()
    }

    // MARK: - Add and synchronous seed

    func testWaitingOnIsSelfScopedAppStampedBoundedReplaceableAndClearable() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)

        let didSet = await fixture.bridge.setWaitingOn(
            summary: "  blocked\n" + String(repeating: "é", count: 300),
            for: fixture.target.domainEndpoint
        )
        XCTAssertTrue(didSet)
        let first = try XCTUnwrap(fixture.host.waitingOnByEndpoint[fixture.target.domainEndpoint])
        XCTAssertEqual(first.declaredAt, Date(timeIntervalSince1970: 1000))
        XCTAssertLessThanOrEqual(first.summary.utf8.count, 280)
        XCTAssertFalse(first.summary.contains("\n"))

        let didReplace = await fixture.bridge.setWaitingOn(
            summary: "review approval",
            for: fixture.target.domainEndpoint
        )
        XCTAssertTrue(didReplace)
        XCTAssertEqual(
            fixture.host.waitingOnByEndpoint[fixture.target.domainEndpoint]?.summary,
            "review approval"
        )

        let didClear = await fixture.bridge.setWaitingOn(
            summary: nil,
            for: fixture.target.domainEndpoint
        )
        XCTAssertTrue(didClear)
        XCTAssertNil(fixture.host.waitingOnByEndpoint[fixture.target.domainEndpoint])

        let unrelated = makeCandidate(windowID: 3)
        fixture.host.candidates.append(unrelated)
        let unrelatedResult = await fixture.bridge.setWaitingOn(
            summary: "no link",
            for: unrelated.domainEndpoint
        )
        XCTAssertFalse(unrelatedResult)
    }

    func testAddSeedsTheFirstLinkBeforeItBecomesAuthorizable() async throws {
        let fixture = makeFixture()
        let outcome = await addLink(fixture)
        guard case .added = outcome else { return XCTFail("expected added, got \(outcome)") }

        // The very first authorized poll must already see a seeded snapshot; there is no window in
        // which an active link exists with no target state.
        let rawState = await pollState(fixture)
        let state = try XCTUnwrap(rawState)
        XCTAssertEqual(state.snapshot.sessionID, fixture.target.sessionID)
        XCTAssertEqual(state.snapshot.latestVisibleAssistantPreview, "seeded")
        XCTAssertEqual(state.snapshot.displayName, "Build API")
        XCTAssertFalse(state.waitCursor.isEmpty)
    }

    func testSeedFailureRollsBackTheReservationAndLeavesNoActiveLink() async {
        let fixture = makeFixture()
        // Drift between the resolution read and the post-reservation revalidation read.
        //
        // Add takes three candidate snapshots: (1) the pre-persistence preflight that renders the
        // popover's message, (2) the shared establishment path's own fresh resolution, and (3) the
        // post-reservation revalidation. Only a drift landing after (2) exercises the seed rollback;
        // dropping the target before (2) is an ordinary `.notFound` resolution failure instead.
        fixture.host.onCandidatesRead = { [weak host = fixture.host] count in
            guard count == 3, let host else { return }
            host.candidates = [fixture.observer]
        }
        let outcome = await addLink(fixture)
        XCTAssertEqual(outcome, .failed(.rebinding))
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
        let observed1 = await pollState(fixture)
        XCTAssertNil(observed1)
    }

    func testMalformedSelfAndChildTargetsAreRejectedWithSpecificReasons() async {
        let fixture = makeFixture()

        let malformed = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: "not-a-uuid"
        )
        XCTAssertEqual(malformed, .failed(.malformedIdentifier))

        let selfMonitor = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: fixture.observer.sessionID.uuidString
        )
        XCTAssertEqual(selfMonitor, .failed(.selfMonitor))

        let child = makeCandidate(windowID: 3, isTopLevel: false)
        fixture.host.candidates = [fixture.observer, child]
        let childOutcome = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: child.sessionID.uuidString
        )
        XCTAssertEqual(childOutcome, .failed(.childSession))

        let observed2 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed2, 0)
    }

    func testAmbiguousTargetIsNeverSilentlyResolved() async {
        let fixture = makeFixture()
        let duplicate = makeCandidate(windowID: 3, sessionID: fixture.target.sessionID)
        fixture.host.candidates = [fixture.observer, fixture.target, duplicate]
        let observed3 = await addLink(fixture)
        XCTAssertEqual(observed3, .failed(.ambiguous))
        let observed4 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed4, 0)
    }

    func testDuplicatePairReturnsTheExistingLinkWithoutASecondGeneration() async {
        let fixture = makeFixture()
        guard case let .added(firstLinkID, _) = await addLink(fixture) else {
            return XCTFail("first add failed")
        }
        let second = await addLink(fixture)
        XCTAssertEqual(second, .alreadyLinked(linkID: firstLinkID, targetSessionID: fixture.target.sessionID))
        let observed5 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed5, 1)
    }

    func testExactAddSelectsPresentedIncarnationsAmidDuplicateUUIDsAndIsIdempotent() async throws {
        let fixture = makeFixture()
        let duplicateObserver = makeCandidate(
            windowID: 3,
            sessionID: fixture.observer.sessionID,
            displayName: "Planning duplicate"
        )
        let duplicateTarget = makeCandidate(
            windowID: 4,
            sessionID: fixture.target.sessionID,
            displayName: "Build API duplicate"
        )
        fixture.host.candidates = [
            duplicateObserver,
            duplicateTarget,
            fixture.observer,
            fixture.target
        ]

        let first = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )
        guard case let .added(linkID, _) = first else {
            return XCTFail("exact add failed: \(first)")
        }
        let exactInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let item = try XCTUnwrap(exactInputs.outbound.items.first)
        XCTAssertEqual(item.linkID, linkID)
        XCTAssertEqual(
            exactInputs.outboundTargetEndpoints[linkID],
            fixture.target.domainEndpoint
        )
        let duplicateObserverInputs = await fixture.authority.projectionInputs(
            forEndpoint: duplicateObserver.domainEndpoint
        )
        let duplicateTargetInputs = await fixture.authority.projectionInputs(
            forEndpoint: duplicateTarget.domainEndpoint
        )
        XCTAssertTrue(duplicateObserverInputs.outbound.items.isEmpty)
        XCTAssertTrue(duplicateTargetInputs.inbound.items.isEmpty)

        let repeated = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )
        XCTAssertEqual(
            repeated,
            .alreadyLinked(
                linkID: linkID,
                targetSessionID: fixture.target.sessionID
            )
        )
        let afterRepeated = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertEqual(afterRepeated.outbound.items.first?.generation, item.generation)
        let activeCount = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(activeCount, 1)
    }

    func testExactAddRevalidatesObserverEligibilityBeforeMutatingAuthority() async {
        let fixture = makeFixture()
        let deniedObserver = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration,
            roleAllowsOutboundMonitoring: false,
            displayName: fixture.observer.displayName ?? "Planning"
        )
        XCTAssertEqual(deniedObserver.domainEndpoint, fixture.observer.domainEndpoint)
        fixture.host.candidates = [deniedObserver, fixture.target]

        let outcome = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        )

        XCTAssertEqual(
            outcome,
            .rejected(message: AgentSessionLinkEndpointEligibility.roleDeniedReason)
        )
        let activeCount = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(activeCount, 0)
    }

    func testExactAddRevokesWhenObserverEligibilityDriftsDuringTailAwait() async {
        let authority = makeAuthority()
        let host = FakeEndpointHost()
        let observer = makeCandidate(windowID: 1, displayName: "Planning")
        let target = makeCandidate(windowID: 2, displayName: "Build API")
        let deniedObserver = makeCandidate(
            windowID: observer.windowID,
            sessionID: observer.sessionID,
            workspaceID: observer.workspaceID,
            tabID: observer.tabID,
            persistentBindingGeneration: observer.persistentBindingGeneration,
            bindingTransitionGeneration: observer.bindingTransitionGeneration,
            roleAllowsOutboundMonitoring: false,
            displayName: observer.displayName ?? "Planning"
        )
        host.candidates = [observer, target]
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { sessionID in
                guard sessionID == target.sessionID else { return }
                await MainActor.run {
                    host.candidates = [deniedObserver, target]
                }
            }
        )

        let outcome = await bridge.addMonitorLink(
            observerEndpoint: observer.domainEndpoint,
            targetEndpoint: target.domainEndpoint
        )

        XCTAssertEqual(outcome, .failed(.rebinding))
        let activeCount = await authority.snapshot().activeLinkCount
        XCTAssertEqual(activeCount, 0, "tail drift must revoke the grant before Add reports failure")
    }

    func testForkInheritanceMintsFreshDirectLinksWithoutTransitiveTargetsAndIsIdempotent() async throws {
        let fixture = makeFixture()
        let child = makeCandidate(windowID: 3, displayName: "Handoff child")
        let transitiveTarget = makeCandidate(windowID: 4, displayName: "Transitive target")
        fixture.host.candidates = [fixture.observer, fixture.target, child, transitiveTarget]

        guard case let .added(parentLinkID, _) = await addLink(fixture) else {
            return XCTFail("parent add failed")
        }
        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.target.sessionID,
            rawTargetSessionID: transitiveTarget.sessionID.uuidString
        ) else {
            return XCTFail("transitive setup add failed")
        }

        let first = await fixture.bridge.inheritActiveOutboundTargets(
            from: fixture.observer.domainEndpoint,
            to: child.domainEndpoint
        )

        XCTAssertEqual(
            first,
            AgentSessionLinkForkInheritanceSummary(
                consideredCount: 1,
                addedCount: 1,
                alreadyLinkedCount: 0,
                skippedCount: 0
            )
        )
        let childInputs = await fixture.authority.projectionInputs(forEndpoint: child.domainEndpoint)
        XCTAssertEqual(childInputs.outbound.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertTrue(childInputs.inbound.items.isEmpty)
        let childLinkID = try XCTUnwrap(childInputs.outbound.items.first?.linkID)
        XCTAssertNotEqual(childLinkID, parentLinkID, "Inheritance must mint a fresh grant reference.")
        XCTAssertFalse(
            childInputs.outbound.items.contains { $0.targetSessionID == transitiveTarget.sessionID },
            "Only the parent's direct outbound inventory is inherited."
        )
        XCTAssertFalse(
            childInputs.outbound.items.contains { $0.targetSessionID == fixture.observer.sessionID },
            "Handoff does not synthesize a child-to-parent link."
        )

        let repeated = await fixture.bridge.inheritActiveOutboundTargets(
            from: fixture.observer.domainEndpoint,
            to: child.domainEndpoint
        )
        XCTAssertEqual(
            repeated,
            AgentSessionLinkForkInheritanceSummary(
                consideredCount: 1,
                addedCount: 0,
                alreadyLinkedCount: 1,
                skippedCount: 0
            )
        )
        let repeatedInventory = await fixture.authority.links(forObserver: child.sessionID)
        XCTAssertEqual(repeatedInventory.items.count, 1)
        XCTAssertEqual(repeatedInventory.items.first?.linkID, childLinkID)
    }

    func testForkInheritanceUsesTheCapturedExactParentWhenItsSessionUUIDIsDuplicated() async {
        let fixture = makeFixture()
        let child = makeCandidate(windowID: 3, displayName: "Handoff child")
        fixture.host.candidates = [fixture.observer, fixture.target, child]
        guard case .added = await addLink(fixture) else { return XCTFail("parent add failed") }
        let duplicateParent = makeCandidate(
            windowID: 4,
            sessionID: fixture.observer.sessionID,
            displayName: "Duplicate parent incarnation"
        )
        fixture.host.candidates.append(duplicateParent)

        let summary = await fixture.bridge.inheritActiveOutboundTargets(
            from: fixture.observer.domainEndpoint,
            to: child.domainEndpoint
        )

        XCTAssertEqual(
            summary,
            AgentSessionLinkForkInheritanceSummary(
                consideredCount: 1,
                addedCount: 1,
                alreadyLinkedCount: 0,
                skippedCount: 0
            )
        )
        let childInputs = await fixture.authority.projectionInputs(forEndpoint: child.domainEndpoint)
        XCTAssertEqual(childInputs.outbound.items.map(\.targetSessionID), [fixture.target.sessionID])
        let duplicateInputs = await fixture.authority.projectionInputs(
            forEndpoint: duplicateParent.domainEndpoint
        )
        XCTAssertTrue(duplicateInputs.outbound.items.isEmpty)
    }

    func testForkInheritanceSkipsAnAmbiguousFrozenTargetAndContinuesBestEffort() async {
        let fixture = makeFixture()
        let child = makeCandidate(windowID: 3, displayName: "Handoff child")
        let secondTarget = makeCandidate(windowID: 4, displayName: "Second target")
        fixture.host.candidates = [fixture.observer, fixture.target, child, secondTarget]
        guard case .added = await addLink(fixture) else { return XCTFail("first parent add failed") }
        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: secondTarget.sessionID.uuidString
        ) else {
            return XCTFail("second parent add failed")
        }

        let duplicate = makeCandidate(
            windowID: 5,
            sessionID: fixture.target.sessionID,
            displayName: "Ambiguous replacement"
        )
        fixture.host.candidates.append(duplicate)

        let summary = await fixture.bridge.inheritActiveOutboundTargets(
            from: fixture.observer.domainEndpoint,
            to: child.domainEndpoint
        )

        XCTAssertEqual(summary.consideredCount, 2)
        XCTAssertEqual(summary.addedCount, 1)
        XCTAssertEqual(summary.alreadyLinkedCount, 0)
        XCTAssertEqual(summary.skippedCount, 1)
        let childInventory = await fixture.authority.links(forObserver: child.sessionID)
        XCTAssertEqual(childInventory.items.map(\.targetSessionID), [secondTarget.sessionID])
    }

    // MARK: - Observation ownership

    func testSecondObserverJoinsWithoutReinstallingTargetObservation() async {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]

        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        XCTAssertEqual(fixture.host.installCountsBySession[fixture.target.sessionID], 1)

        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed: \(second)") }

        // Activation-time `installsTargetObservation` is the authority: the joining observer must not
        // install a second observation or a second publication chain.
        XCTAssertEqual(fixture.host.installCountsBySession[fixture.target.sessionID], 1)
        let observed6 = await fixture.authority.snapshot().observedTargetCount
        XCTAssertEqual(observed6, 1)
    }

    /// Regression: a joining observer must not overwrite the installing chain's dedupe state.
    ///
    /// `activateLink` deliberately ignores the seed of an activation that joins an existing target
    /// record. Recording that ignored seed as "already published" made the installing chain's next
    /// rebuild compare equal and be dropped, so `change_sequence` never advanced and every `poll` and
    /// `wait` stayed on the pre-join snapshot until an unrelated mutation.
    func testJoiningObserverDoesNotSuppressTheTargetsNextPublication() async throws {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let rawSeeded = await pollState(fixture)
        let seeded = try XCTUnwrap(rawSeeded)
        XCTAssertEqual(seeded.snapshot.status, .idle)

        // The target moves on *before* the second observer joins, so the seed the joining activation
        // computes is strictly newer than what the authority stored.
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: "working",
            visibleRowCount: 5,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed: \(second)") }

        // The installing chain now rebuilds the same live state it had while the join happened.
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let rawUpdated = await pollState(fixture)
        let updated = try XCTUnwrap(rawUpdated)
        XCTAssertEqual(
            updated.snapshot.status,
            .running,
            "The joining observer's ignored seed must not mask the installing chain's publication"
        )
        XCTAssertGreaterThan(
            updated.changeSequence,
            seeded.changeSequence,
            "A stranded dedupe value freezes change_sequence and strands every parked wait"
        )
        let rawJoined = await pollState(fixture, observer: secondObserver)
        let joined = try XCTUnwrap(rawJoined)
        XCTAssertEqual(joined.snapshot.status, .running)
    }

    /// Regression: monitor authority is endpoint-bound, so a duplicate live incarnation of the
    /// granted observer session UUID inherits nothing.
    func testDuplicateObserverIncarnationInheritsNoGrantAdvertisementOrPublication() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Another window holds the same session UUID: a different tab, a different persistent
        // binding, and no grant of its own.
        let duplicate = makeCandidate(
            windowID: fixture.observer.windowID + 10,
            sessionID: fixture.observer.sessionID,
            displayName: "Planning (duplicate)"
        )
        fixture.host.candidates = [fixture.observer, fixture.target, duplicate]

        let authorized = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: duplicate.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertEqual(authorized.failure, .denied)
        let duplicateInventory = await fixture.bridge
            .inventory(forObserverEndpoint: duplicate.domainEndpoint)
        XCTAssertEqual(duplicateInventory.failure, .denied)
        let duplicateAdvertised = await fixture.bridge
            .hasActiveOutboundLink(observerEndpoint: duplicate.domainEndpoint)
        XCTAssertFalse(duplicateAdvertised)

        // The granted incarnation is unaffected: the duplicate's denial must not revoke anything.
        let granted = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertNotNil(granted.success)

        // Publication is addressed to exact incarnations, so the duplicate is never handed the
        // granted incarnation's rows or its agent-facing prompt inventory.
        await fixture.bridge.test_settleProjections()
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[fixture.observer.domainEndpoint]?
                .outbound.map(\.targetSessionID),
            [fixture.target.sessionID],
            "The granted incarnation still renders its own outbound row"
        )
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[duplicate.domainEndpoint]?.outbound.count,
            0,
            "A duplicate incarnation must never render another incarnation's outbound rows"
        )
        XCTAssertEqual(
            fixture.host.publishedInventoriesByEndpoint[duplicate.domainEndpoint]?.items.count,
            0,
            "...and must never be told, in its own prompt, that it is overseeing anything"
        )
    }

    func testObservationIsTornDownOnlyAfterTheLastInboundLink() async {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]

        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed") }

        guard let first = await linkReference(fixture),
              let other = await linkReference(fixture, observer: secondObserver.sessionID)
        else { return XCTFail("missing link references") }

        await fixture.bridge.revokeLink(linkID: first.linkID, generation: first.generation)
        XCTAssertNotNil(
            fixture.host.liveObservations[fixture.target.sessionID],
            "observation torn down while another inbound link remained"
        )

        await fixture.bridge.revokeLink(linkID: other.linkID, generation: other.generation)
        XCTAssertNil(fixture.host.liveObservations[fixture.target.sessionID])
        let observed7 = await fixture.authority.snapshot().observedTargetCount
        XCTAssertEqual(observed7, 0)
    }

    // MARK: - Serialized publication

    func testObservationPublishesMonotonicallyAndAdvancesChangeSequence() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        let rawSeeded = await pollState(fixture)
        let seeded = try XCTUnwrap(rawSeeded)

        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: "working",
            visibleRowCount: 5,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let rawUpdated = await pollState(fixture)
        let updated = try XCTUnwrap(rawUpdated)
        XCTAssertEqual(updated.snapshot.status, .running)
        XCTAssertFalse(updated.snapshot.idleForSend)
        XCTAssertGreaterThan(updated.changeSequence, seeded.changeSequence)
    }

    func testARepublishAfterReinstallIsNeverRejectedAsStale() async throws {
        // The source publication sequence is never reset per target record, so a chain that is torn
        // down and reinstalled continues above the previous high-water mark.
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        guard let first = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: first.linkID, generation: first.generation)
        guard case .added = await addLink(fixture) else { return XCTFail("re-add failed") }

        let rawSeeded = await pollState(fixture)
        let seeded = try XCTUnwrap(rawSeeded)
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .awaitingUser,
            idleForSend: false,
            pendingInteractionKind: .approval,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 9,
            lastActivityAt: Date(timeIntervalSince1970: 300)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let rawUpdated = await pollState(fixture)
        let updated = try XCTUnwrap(rawUpdated)
        XCTAssertEqual(updated.snapshot.status, .awaitingUser)
        XCTAssertEqual(updated.snapshot.pendingInteractionKind, .approval)
        XCTAssertGreaterThan(updated.changeSequence, seeded.changeSequence)
    }

    /// Regression: a second live incarnation of the *target's* session UUID must not revoke the
    /// granted link.
    ///
    /// Publication used to resolve its target with an exactly-one-UUID-match lookup, so opening a
    /// duplicate incarnation anywhere in the process made that lookup ambiguous, and the bridge read
    /// the ambiguity as `.targetIdentityDrift` and revoked a link that had not drifted at all.
    func testDuplicateTargetIncarnationDoesNotRevokeTheGrantedLink() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Another window opens the same session UUID. The granted incarnation is untouched.
        let duplicate = makeCandidate(
            windowID: fixture.target.windowID + 10,
            sessionID: fixture.target.sessionID,
            displayName: "Build API (duplicate)"
        )
        fixture.host.candidates = [fixture.observer, fixture.target, duplicate]

        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: "still here",
            visibleRowCount: 4,
            lastActivityAt: Date(timeIntervalSince1970: 400)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let activeLinks = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(activeLinks, 1, "a duplicate incarnation is not drift")
        let rawState = await pollState(fixture)
        let state = try XCTUnwrap(rawState)
        XCTAssertEqual(
            state.snapshot.status,
            .running,
            "the granted incarnation must keep publishing through the duplicate's lifetime"
        )
    }

    /// Regression: projection peers are resolved by exact incarnation, not by first-wins session UUID.
    ///
    /// With a `[sessionID: candidate]` map an arbitrary incarnation won, so an outbound row could
    /// show a duplicate's provider/location/status and an inbound row a duplicate's name.
    func testProjectionRowsDescribeTheGrantedIncarnationNotADuplicate() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Duplicates of *both* endpoints, each with deliberately different renderable facts.
        var duplicateTarget = makeCandidate(
            windowID: fixture.target.windowID + 10,
            sessionID: fixture.target.sessionID,
            displayName: "Build API (duplicate)"
        )
        duplicateTarget = AgentSessionLinkEndpointCandidate(
            windowID: duplicateTarget.windowID,
            workspaceID: duplicateTarget.workspaceID,
            tabID: duplicateTarget.tabID,
            sessionID: duplicateTarget.sessionID,
            persistentBindingGeneration: duplicateTarget.persistentBindingGeneration,
            bindingTransitionGeneration: duplicateTarget.bindingTransitionGeneration,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Build API (duplicate)",
            providerDisplayName: "Claude Code",
            locationLabel: "worktree/duplicate"
        )
        let duplicateObserver = makeCandidate(
            windowID: fixture.observer.windowID + 10,
            sessionID: fixture.observer.sessionID,
            displayName: "Planning (duplicate)"
        )
        // Ordered so a first-wins UUID map would pick the duplicates.
        fixture.host.candidates = [duplicateObserver, duplicateTarget, fixture.observer, fixture.target]
        await fixture.bridge.test_settleProjections()

        let observerProps = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.observer.domainEndpoint]
        )
        let outbound = try XCTUnwrap(observerProps.outbound.first)
        XCTAssertEqual(
            outbound.providerDisplayName,
            "Codex CLI",
            "the row must describe the granted target incarnation"
        )
        XCTAssertEqual(outbound.locationLabel, "worktree/main")
        XCTAssertEqual(outbound.lastActivityAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            outbound.targetRoute,
            AgentSessionDeepLinkRoute(
                windowID: fixture.target.windowID,
                workspaceID: fixture.target.workspaceID,
                tabID: fixture.target.tabID,
                sessionID: fixture.target.sessionID
            )
        )

        let targetProps = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.target.domainEndpoint]
        )
        XCTAssertEqual(
            targetProps.inbound.first?.displayName,
            "Planning",
            "the inbound row must name the granted observer incarnation"
        )
    }

    func testTargetMenuProjectsMultipleLinkedObserversAndExactPeerEndpoints() async throws {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        let availableObserver = makeCandidate(windowID: 4, displayName: "Review")
        fixture.host.candidates = [
            fixture.observer,
            fixture.target,
            secondObserver,
            availableObserver
        ]
        guard case .added = await addLink(fixture),
              case .added = await fixture.bridge.addMonitorLink(
                  observerSessionID: secondObserver.sessionID,
                  rawTargetSessionID: fixture.target.sessionID.uuidString
              ), case .added = await fixture.bridge.addMonitorLink(
                  observerEndpoint: availableObserver.domainEndpoint,
                  targetEndpoint: fixture.observer.domainEndpoint
              )
        else {
            return XCTFail("setup links failed")
        }
        await fixture.bridge.test_settleProjections()

        let targetProps = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.target.domainEndpoint]
        )
        let menu = try XCTUnwrap(targetProps.sidebarOversightMenu)
        XCTAssertEqual(menu.targetEndpoint, fixture.target.domainEndpoint)
        XCTAssertEqual(
            Set(menu.linkedObservers.map(\.observerEndpoint)),
            [fixture.observer.domainEndpoint, secondObserver.domainEndpoint]
        )
        XCTAssertEqual(menu.availableObservers.map(\.observerEndpoint), [availableObserver.domainEndpoint])
        XCTAssertTrue(menu.linkedObservers.allSatisfy { option in
            guard case .linked(_, observerCurrentlyEligible: true) = option.relationship else {
                return false
            }
            return true
        })
        XCTAssertEqual(Set(targetProps.inbound.map(\.observerEndpoint)), [
            fixture.observer.domainEndpoint,
            secondObserver.domainEndpoint
        ])
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[fixture.observer.domainEndpoint]?
                .outbound.first?.targetEndpoint,
            fixture.target.domainEndpoint
        )
    }

    func testTargetMenuOffersOnlyExistingOverseersButRetainsUnavailableLinkedObserver() async throws {
        let fixture = makeFixture()
        let existingOverseer = makeCandidate(windowID: 3, displayName: "Existing overseer")
        let ordinaryLane = makeCandidate(windowID: 4, displayName: "Ordinary lane")
        fixture.host.candidates = [
            fixture.observer,
            fixture.target,
            existingOverseer,
            ordinaryLane
        ]
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ), case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: existingOverseer.domainEndpoint,
            targetEndpoint: fixture.observer.domainEndpoint
        ) else {
            return XCTFail("setup links failed")
        }
        await fixture.bridge.test_settleProjections()
        XCTAssertTrue(try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[existingOverseer.domainEndpoint]
        ).isOverseer)
        XCTAssertFalse(try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[ordinaryLane.domainEndpoint]
        ).isOverseer)

        // Keep the authority relationship but remove its live candidate. This is the unlink path that
        // must survive an observer closing or otherwise becoming unavailable.
        fixture.host.candidates = [fixture.target, existingOverseer, ordinaryLane]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleMonitorProjectionRefresh()

        let menu = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.target.domainEndpoint]?.sidebarOversightMenu
        )
        XCTAssertEqual(menu.linkedObservers.map(\.observerEndpoint), [fixture.observer.domainEndpoint])
        guard case .linked(_, observerCurrentlyEligible: false) = menu.linkedObservers.first?.relationship else {
            return XCTFail("the unavailable linked observer must remain visible for unlink")
        }
        XCTAssertEqual(
            menu.availableObservers.map(\.displayName),
            ["Existing overseer"],
            "ordinary live Agent lanes must not appear as Add choices"
        )
    }

    func testSidebarAddFailsClosedWhenPresentedOverseerLosesItsFinalLinkBeforeActivation() async throws {
        let fixture = makeFixture()
        let newTarget = makeCandidate(windowID: 3, displayName: "New target")
        fixture.host.candidates = [fixture.observer, fixture.target, newTarget]
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ) else {
            return XCTFail("setup link failed")
        }
        await fixture.bridge.test_settleProjections()
        let presentedMenu = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[newTarget.domainEndpoint]?.sidebarOversightMenu
        )
        XCTAssertEqual(
            presentedMenu.availableObservers.map(\.observerEndpoint),
            [fixture.observer.domainEndpoint]
        )
        let currentReference = await linkReference(fixture)
        let existingReference = try XCTUnwrap(currentReference)
        let pair = AgentSessionOversightIntent(
            observerSessionID: fixture.observer.sessionID,
            targetSessionID: newTarget.sessionID
        )
        var revokedDuringAdd = false
        fixture.bridge.test_afterReservationBeforeActivation = { pendingPair in
            guard pendingPair == pair, !revokedDuringAdd else { return }
            revokedDuringAdd = true
            let disposition = await fixture.authority.revoke(
                linkID: existingReference.linkID,
                generation: existingReference.generation,
                reason: .userRequested
            )
            guard case .revoked = disposition else {
                return XCTFail("expected the former overseer's final link to revoke")
            }
        }

        let outcome = await fixture.bridge.addSidebarMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: newTarget.domainEndpoint
        )

        XCTAssertTrue(revokedDuringAdd)
        XCTAssertEqual(
            outcome,
            .rejected(message: AgentSessionLinkRuntimeBridge.existingOverseerRequiredMessage)
        )
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.pendingReservationCount, 0)
        let remainsOverseer = await fixture.authority.hasActiveOutboundLink(
            observerEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertFalse(remainsOverseer)
    }

    func testExactStopUnlinksOnlyTheSelectedObserverFromAMultiObserverTarget() async throws {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, secondObserver, fixture.target]
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ), case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: secondObserver.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ) else {
            return XCTFail("setup links failed")
        }
        let firstInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let firstItem = try XCTUnwrap(firstInputs.outbound.items.first)
        let firstReference = DomainAgentSessionLinkReference(
            linkID: firstItem.linkID,
            generation: firstItem.generation
        )

        let outcome = await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: firstReference
        )

        XCTAssertEqual(outcome, .stopped)
        let stoppedInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let survivingInputs = await fixture.authority.projectionInputs(
            forEndpoint: secondObserver.domainEndpoint
        )
        let targetInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.target.domainEndpoint
        )
        XCTAssertTrue(stoppedInputs.outbound.items.isEmpty)
        XCTAssertEqual(survivingInputs.outbound.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertEqual(targetInputs.inbound.items.map(\.observerSessionID), [secondObserver.sessionID])
        XCTAssertEqual(fixture.host.installCountsBySession[fixture.target.sessionID], 1)
    }

    func testExactStopRejectsMismatchedGrantEndpointsWithoutMutation() async throws {
        let fixture = makeFixture()
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ) else {
            return XCTFail("setup add failed")
        }
        let inputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let item = try XCTUnwrap(inputs.outbound.items.first)
        let reference = DomainAgentSessionLinkReference(
            linkID: item.linkID,
            generation: item.generation
        )
        let wrongObserver = makeCandidate(
            windowID: 9,
            sessionID: fixture.observer.sessionID,
            displayName: "Wrong observer incarnation"
        )
        let wrongTarget = makeCandidate(
            windowID: 10,
            sessionID: fixture.target.sessionID,
            displayName: "Wrong target incarnation"
        )
        let authorityBefore = await fixture.authority.snapshot()

        let observerMismatch = await fixture.bridge.stopMonitorLink(
            observerEndpoint: wrongObserver.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: reference
        )
        let targetMismatch = await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: wrongTarget.domainEndpoint,
            expectedReference: reference
        )

        let staleMessage = "That oversight relationship is no longer active."
        XCTAssertEqual(observerMismatch, .failed(message: staleMessage))
        XCTAssertEqual(targetMismatch, .failed(message: staleMessage))
        let authorityAfter = await fixture.authority.snapshot()
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        XCTAssertEqual(authorityAfter, authorityBefore)
        XCTAssertEqual(activeGrant?.observer, fixture.observer.domainEndpoint)
        XCTAssertEqual(activeGrant?.target, fixture.target.domainEndpoint)
    }

    func testDeadObserverCanBeUnlinkedFromTheTargetsAuthorityRecordedGrant() async throws {
        let fixture = makeFixture()
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint
        ) else {
            return XCTFail("setup add failed")
        }
        let inputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.observer.domainEndpoint
        )
        let item = try XCTUnwrap(inputs.outbound.items.first)
        let reference = DomainAgentSessionLinkReference(
            linkID: item.linkID,
            generation: item.generation
        )
        // Do not run a stale-endpoint sweep. The menu captured this exact authority relationship
        // while the observer was live; Stop must not require that candidate to remain available.
        fixture.host.candidates = [fixture.target]

        let outcome = await fixture.bridge.stopMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: fixture.target.domainEndpoint,
            expectedReference: reference
        )

        XCTAssertEqual(outcome, .stopped)
        let activeGrant = await fixture.authority.activeGrant(for: reference)
        let targetInputs = await fixture.authority.projectionInputs(
            forEndpoint: fixture.target.domainEndpoint
        )
        XCTAssertNil(activeGrant)
        XCTAssertTrue(targetInputs.inbound.items.isEmpty)
    }

    func testCandidateReadinessRepaintsMenusWithoutPromptInventoryPassiveSamplesOrAuthorityChanges() async throws {
        let fixture = makeFixture()
        let otherTarget = makeCandidate(
            windowID: 3,
            roleAllowsOutboundMonitoring: false,
            displayName: "Other target"
        )
        fixture.host.candidates.append(otherTarget)
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetEndpoint: otherTarget.domainEndpoint
        ) else {
            return XCTFail("setup link failed")
        }
        await fixture.bridge.test_settleProjections()
        let before = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.target.domainEndpoint]?.sidebarOversightMenu
        )
        XCTAssertEqual(before.availableObservers.map(\.observerEndpoint), [fixture.observer.domainEndpoint])
        let inventoryBefore = fixture.host.publishedInventoriesByEndpoint
        let passivePublicationsBefore = fixture.host.passiveNoticePublicationCount
        let authorityBefore = await fixture.authority.snapshot()

        let loadingObserver = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration,
            hasLoadedPersistedState: false,
            displayName: fixture.observer.displayName ?? "Planning"
        )
        fixture.host.candidates = [loadingObserver, fixture.target, otherTarget]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleMonitorProjectionRefresh()

        let repainted = try XCTUnwrap(
            fixture.host.publishedPropsByEndpoint[fixture.target.domainEndpoint]?.sidebarOversightMenu
        )
        XCTAssertTrue(repainted.availableObservers.isEmpty)
        XCTAssertEqual(fixture.host.publishedInventoriesByEndpoint, inventoryBefore)
        XCTAssertEqual(fixture.host.passiveNoticePublicationCount, passivePublicationsBefore)
        let authorityAfter = await fixture.authority.snapshot()
        XCTAssertEqual(authorityAfter, authorityBefore)
    }

    // MARK: - Activity high-water

    func testActivityHighWaterObservedByOneSeenActionIsRetainedForEveryExactTargetObserver() async {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let secondOutcome = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = secondOutcome,
              let firstReference = await linkReference(fixture),
              let secondReference = await linkReference(fixture, observer: secondObserver.sessionID)
        else { return XCTFail("missing active links") }

        XCTAssertNotEqual(firstReference, secondReference)

        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        let markedSeen = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: firstReference
        )
        XCTAssertEqual(markedSeen, .marked)
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(
            fixture.host.publishedProps[fixture.observer.sessionID]?.outbound.first?.hasUnreadActivity,
            false
        )

        // A later regressed sample cannot hide the high-water from the other observer.
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .idle,
            idleForSend: true,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: 50)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleMonitorProjectionRefresh()

        XCTAssertEqual(
            fixture.host.publishedProps[secondObserver.sessionID]?.outbound.first?.lastActivityAt,
            Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            fixture.host.publishedProps[secondObserver.sessionID]?.outbound.first?.hasUnreadActivity,
            true,
            "the other exact observer must still compare its own baseline with the target high-water"
        )
    }

    // MARK: - Unread since seen

    func testSeenUsesPollAuthorization() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture),
              let reference = await linkReference(fixture)
        else { return XCTFail("missing active link") }
        await publishTargetActivity(fixture, status: .running, activity: 200)

        var observedOperations: [DomainAgentSessionTargetOperation] = []
        fixture.bridge.test_observeSeenAuthorizationOperation = { operation in
            observedOperations.append(operation)
        }

        let markedSeen = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        fixture.bridge.test_observeSeenAuthorizationOperation = nil

        XCTAssertEqual(markedSeen, .marked)
        XCTAssertEqual(observedOperations, [.monitorPoll])
    }

    func testSeenCommitsPostValidationActivityAndDeniesAReboundTarget() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture),
              let reference = await linkReference(fixture)
        else { return XCTFail("missing active link") }

        let settledDuringValidation = Date(timeIntervalSince1970: 200)
        fixture.bridge.test_duringFinalSeenLeaseValidation = {
            fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
                sessionID: fixture.target.sessionID,
                displayName: "Build API",
                providerDisplayName: "Codex CLI",
                status: .running,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 1,
                lastActivityAt: settledDuringValidation
            )
            await Task.yield()
        }

        let markedSeen = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        fixture.bridge.test_duringFinalSeenLeaseValidation = nil
        XCTAssertEqual(markedSeen, .marked)
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(outboundRow(fixture)?.lastActivityAt, settledDuringValidation)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)

        let reboundTarget = makeCandidate(
            windowID: fixture.target.windowID,
            sessionID: fixture.target.sessionID,
            workspaceID: fixture.target.workspaceID,
            tabID: fixture.target.tabID,
            bindingTransitionGeneration: fixture.target.bindingTransitionGeneration + 1,
            displayName: "Build API (rebound)"
        )
        fixture.bridge.test_duringFinalSeenLeaseValidation = {
            fixture.host.candidates = [fixture.observer, reboundTarget]
            await Task.yield()
        }
        let deniedAfterRebind = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        fixture.bridge.test_duringFinalSeenLeaseValidation = nil
        guard case .failed = deniedAfterRebind else {
            return XCTFail("a target rebound during final validation must deny Seen")
        }
    }

    func testUnreadBaselinesReadThenTracksStrictlyNewerActivityUntilAcknowledged() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture),
              let reference = await linkReference(fixture)
        else { return XCTFail("missing active link") }

        // The first authoritative row baselines against current activity: work the target did before
        // the user was granted oversight is not something they missed.
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)
        XCTAssertEqual(outboundRow(fixture)?.lastActivityAt, Date(timeIntervalSince1970: 100))

        await publishTargetActivity(fixture, status: .running, activity: 200)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, true)

        // Repainting an unread row is not review. Only an explicit acknowledgement clears it, which
        // is why opening or scrolling the dashboard changes nothing here.
        await fixture.bridge.test_settleProjections()
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, true)

        let marked = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        XCTAssertEqual(marked, .marked)
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)

        let repeated = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        XCTAssertEqual(repeated, .alreadySeen)

        // A regressed sample cannot re-flag activity the user already acknowledged.
        await publishTargetActivity(fixture, status: .idle, activity: 150)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)
        await publishTargetActivity(fixture, status: .running, activity: 300)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, true)
    }

    func testMarkSeenIsScopedToTheExactObserverAndReference() async {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let secondOutcome = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = secondOutcome,
              let firstReference = await linkReference(fixture),
              let secondReference = await linkReference(fixture, observer: secondObserver.sessionID)
        else { return XCTFail("missing active links") }

        await publishTargetActivity(fixture, status: .running, activity: 200)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, true)
        XCTAssertEqual(outboundRow(fixture, observer: secondObserver.sessionID)?.hasUnreadActivity, true)

        let marked = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: firstReference
        )
        XCTAssertEqual(marked, .marked)
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)
        XCTAssertEqual(
            outboundRow(fixture, observer: secondObserver.sessionID)?.hasUnreadActivity,
            true,
            "acknowledgement is observer-local: one overseer cannot clear another's signal"
        )

        // Another observer's live reference is not a proof of this observer's grant.
        guard case .failed = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: secondReference
        ) else {
            return XCTFail("a foreign reference unexpectedly acknowledged this observer's row")
        }
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(outboundRow(fixture, observer: secondObserver.sessionID)?.hasUnreadActivity, true)
    }

    // MARK: - Passive status notices

    private func passiveSnapshot(
        _ fixture: Fixture,
        observer: AgentSessionLinkEndpointCandidate? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot? {
        fixture.host.publishedPassiveNoticesByEndpoint[(observer ?? fixture.observer).domainEndpoint]
    }

    private func passiveTransitions(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot?
    ) -> [String] {
        snapshot?.entries.map { "\($0.fromStatus.rawValue)->\($0.toStatus.rawValue)" } ?? []
    }

    /// Collection is an always-on property of a live, eligible direct link, so there is nothing to
    /// switch on: settling the authoritative pass is the whole setup.
    private func settlePassive(_ fixture: Fixture) async {
        await fixture.bridge.test_settleMonitorProjectionRefresh()
    }

    func testFirstDirectLinkBaselinesSilentlyAndOnlyTheAuthoritativePassSamplesTransitions() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await settlePassive(fixture)

        // The observer never asked for this and the dashboard switch is a different setting entirely,
        // so it stays off while collection runs.
        XCTAssertEqual(
            fixture.host.publishedProps[fixture.observer.sessionID]?.autoWakeOnUpdatesEnabled,
            false
        )
        let baseline = try XCTUnwrap(passiveSnapshot(fixture))
        XCTAssertTrue(baseline.isEnabled)
        XCTAssertTrue(baseline.isDeliverable)
        XCTAssertTrue(baseline.entries.isEmpty, "the first link is not a claim that past work is news")

        // Ordinary Idle -> Running churn is never narrated.
        await publishTargetActivity(fixture, status: .running, activity: 200)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), [])

        await publishTargetActivity(fixture, status: .idle, activity: 300)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["running->idle"])
        let entry = try XCTUnwrap(passiveSnapshot(fixture)?.entries.first)
        XCTAssertEqual(entry.targetSessionID, fixture.target.sessionID)
        let inventory = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])
        XCTAssertEqual(
            entry.displayName,
            inventory.items.first?.displayName,
            "a queued notice is agent-facing, so it carries the grant's name and not a live substitute"
        )

        // The presentation-only repaint reads exactly the live status the rows do, so it is the path
        // that must not narrate: change status, repaint, and prove nothing was sampled or published.
        let publications = fixture.host.passiveNoticePublicationCount
        let settledRevision = try XCTUnwrap(passiveSnapshot(fixture)?.queueRevision)
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .awaitingUser,
            idleForSend: false,
            pendingInteractionKind: .approval,
            latestVisibleAssistantPreview: nil,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: 400)
        )
        fixture.bridge.requestMonitorLocationRefresh(
            forExactTargetEndpoints: [fixture.target.domainEndpoint]
        )
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(outboundRow(fixture)?.status, .awaitingUser, "the repaint did render the change")
        XCTAssertEqual(fixture.host.passiveNoticePublicationCount, publications)
        XCTAssertEqual(passiveSnapshot(fixture)?.queueRevision, settledRevision)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["running->idle"])

        // The next authoritative pass observes the same change from the *unadvanced* baseline, which
        // is what proves the repaint left the reducer's state alone rather than merely staying quiet.
        // First-to-final coalescing then reports the whole still-pending interval, so the surviving
        // entry opens at `running` — where the interval began — rather than at the intermediate idle.
        await publishTargetActivity(fixture, status: .awaitingUser, activity: 400)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["running->waiting"])
    }

    /// An observer with no direct outbound link publishes no queue at all, so an unrelated endpoint
    /// cannot be handed one by the always-on pass.
    func testAnObserverWithNoDirectLinkGetsNoQueue() async {
        let fixture = makeFixture()
        await settlePassive(fixture)
        XCTAssertTrue(fixture.host.publishedPassiveNoticesByEndpoint.isEmpty)
    }

    func testPassiveQueueFollowsMembershipAndClearsWhenTheLastLinkGoesAway() async {
        let fixture = makeFixture()
        let secondTarget = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondTarget]
        guard case .added = await addLink(fixture),
              case .added = await fixture.bridge.addMonitorLink(
                  observerSessionID: fixture.observer.sessionID,
                  rawTargetSessionID: secondTarget.sessionID.uuidString
              ),
              let secondReference = await linkReference(fixture, target: secondTarget.sessionID),
              let firstReference = await linkReference(fixture)
        else { return XCTFail("missing active links") }

        await settlePassive(fixture)
        for target in [fixture.target, secondTarget] {
            await publishActivity(fixture, for: target, status: .running, activity: 200)
            await publishActivity(fixture, for: target, status: .idle, activity: 300)
        }
        XCTAssertEqual(passiveSnapshot(fixture)?.entries.count, 2)
        XCTAssertEqual(
            passiveSnapshot(fixture)?.linkSetRevision,
            fixture.host.publishedPromptInventories[fixture.observer.sessionID]?.linkSetRevision,
            "a queue that cannot be matched to the current inventory can never be delivered"
        )

        let stoppedSecond = await fixture.bridge.stopMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            targetSessionID: secondTarget.sessionID,
            linkID: secondReference.linkID,
            generation: secondReference.generation
        )
        XCTAssertEqual(stoppedSecond, .stopped)
        XCTAssertEqual(
            passiveSnapshot(fixture)?.entries.map(\.targetSessionID),
            [fixture.target.sessionID],
            "a revoked target's pending notice is pruned rather than left deliverable"
        )
        XCTAssertEqual(
            passiveSnapshot(fixture)?.linkSetRevision,
            fixture.host.publishedPromptInventories[fixture.observer.sessionID]?.linkSetRevision
        )

        // Losing the last link publishes one terminal empty snapshot and drops the reducer, so no
        // backlog can survive hidden and start narrating again when a later link is added.
        let stoppedFirst = await fixture.bridge.stopMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            targetSessionID: fixture.target.sessionID,
            linkID: firstReference.linkID,
            generation: firstReference.generation
        )
        XCTAssertEqual(stoppedFirst, .stopped)
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(passiveSnapshot(fixture)?.isEnabled, false)
        XCTAssertEqual(passiveSnapshot(fixture)?.entries.isEmpty, true)
        XCTAssertEqual(
            fixture.host.publishedProps[fixture.observer.sessionID]?.autoWakeOnUpdatesEnabled,
            false
        )

        // Re-adding a link restarts collection automatically, on a *fresh* queue epoch: the new
        // relationship baselines silently and then narrates its own changes rather than resuming the
        // retired queue's history.
        let retiredEpoch = passiveSnapshot(fixture)?.queueEpoch
        guard case .added = await addLink(fixture) else { return XCTFail("re-add failed") }
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(passiveSnapshot(fixture)?.isEnabled, true)
        XCTAssertNotEqual(passiveSnapshot(fixture)?.queueEpoch, retiredEpoch)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), [])
        XCTAssertEqual(
            fixture.host.publishedProps[fixture.observer.sessionID]?.autoWakeOnUpdatesEnabled,
            false,
            "the persisted setting is untouched by link churn"
        )
        await publishTargetActivity(fixture, status: .running, activity: 400)
        await publishTargetActivity(fixture, status: .idle, activity: 500)
        XCTAssertEqual(
            passiveTransitions(passiveSnapshot(fixture)),
            ["running->idle"],
            "the fresh relationship collects from its own baseline"
        )
    }

    func testPassiveReceiptAppliesOncePerQueueRevisionAndRepublishesImmediately() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await settlePassive(fixture)
        await publishTargetActivity(fixture, status: .running, activity: 200)
        await publishTargetActivity(fixture, status: .idle, activity: 300)

        let claimed = try XCTUnwrap(passiveSnapshot(fixture))
        XCTAssertEqual(claimed.entries.count, 1)
        let receipt = AgentSessionLinkPassiveStatusNotices.Receipt(snapshot: claimed)
        let publications = fixture.host.passiveNoticePublicationCount

        fixture.bridge.applyPassiveMonitorNoticeReceipt(
            receipt,
            observerEndpoint: fixture.observer.domainEndpoint
        )
        let reduced = try XCTUnwrap(passiveSnapshot(fixture))
        XCTAssertTrue(reduced.entries.isEmpty)
        XCTAssertGreaterThan(reduced.queueRevision, claimed.queueRevision)
        XCTAssertEqual(
            fixture.host.passiveNoticePublicationCount,
            publications + 1,
            "the reduced queue must be republished before a second natural dispatch can reclaim it"
        )

        // Duplicate delivery of the same batch, and a receipt addressed to an endpoint that holds no
        // queue, both change nothing.
        fixture.bridge.applyPassiveMonitorNoticeReceipt(
            receipt,
            observerEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertEqual(passiveSnapshot(fixture), reduced)
        fixture.bridge.applyPassiveMonitorNoticeReceipt(
            receipt,
            observerEndpoint: fixture.target.domainEndpoint
        )
        XCTAssertNil(fixture.host.publishedPassiveNoticesByEndpoint[fixture.target.domainEndpoint])

        // A status that changed after the batch was claimed stays owed: the stale receipt cannot
        // acknowledge an edge it never carried.
        await publishTargetActivity(fixture, status: .awaitingUser, activity: 400)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["idle->waiting"])
        fixture.bridge.applyPassiveMonitorNoticeReceipt(
            receipt,
            observerEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["idle->waiting"])
    }

    func testPassiveQueueIsScopedToTheExactObserverIncarnation() async {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]
        guard case .added = await addLink(fixture),
              case .added = await fixture.bridge.addMonitorLink(
                  observerSessionID: secondObserver.sessionID,
                  rawTargetSessionID: fixture.target.sessionID.uuidString
              )
        else { return XCTFail("missing active links") }

        await settlePassive(fixture)
        await publishTargetActivity(fixture, status: .running, activity: 200)
        await publishTargetActivity(fixture, status: .idle, activity: 300)
        XCTAssertEqual(passiveTransitions(passiveSnapshot(fixture)), ["running->idle"])
        XCTAssertEqual(
            passiveTransitions(passiveSnapshot(fixture, observer: secondObserver)),
            ["running->idle"],
            "each overseer collects on its own behalf, from its own baseline"
        )
        XCTAssertEqual(
            fixture.host.publishedProps[secondObserver.sessionID]?.autoWakeOnUpdatesEnabled,
            false
        )

        // The tab rebinds: the retired incarnation's queue is dropped, and the replacement baselines
        // fresh rather than resuming a backlog it was never granted.
        let retiredQueue = passiveSnapshot(fixture)
        let rebound = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: UUID(),
            displayName: "Planning"
        )
        fixture.host.candidates = [rebound, fixture.target, secondObserver]
        await fixture.bridge.invalidateBinding(
            windowID: fixture.observer.windowID,
            tabID: fixture.observer.tabID
        )
        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: rebound.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        ) else { return XCTFail("re-add from the replacement incarnation failed") }

        // The replacement incarnation collects on its own behalf, from its own baseline and its own
        // queue epoch. What must never happen is inheriting the retired incarnation's backlog.
        let reboundQueue = fixture.host.publishedPassiveNoticesByEndpoint[rebound.domainEndpoint]
        XCTAssertEqual(reboundQueue?.entries.isEmpty, true)
        XCTAssertNotEqual(reboundQueue?.queueEpoch, retiredQueue?.queueEpoch)
        XCTAssertEqual(
            fixture.host.publishedProps[rebound.sessionID]?.autoWakeOnUpdatesEnabled,
            false
        )

        // Nothing publishes to the *retired* endpoint again: its queue was dropped rather than left
        // paused, so a completion the replacement never subscribed to cannot reach it.
        await publishTargetActivity(fixture, status: .running, activity: 400)
        await publishTargetActivity(fixture, status: .idle, activity: 500)
        XCTAssertEqual(
            passiveSnapshot(fixture),
            retiredQueue,
            "the retired incarnation's last snapshot is the last thing it ever received"
        )
    }

    // MARK: - Auto-wake snooze routing

    /// The bridge owns routing, not policy: it re-proves the exact observer incarnation and the exact
    /// outbound link generation, then hands the decision to the live owning session.
    func testAutoWakeSnoozeMutationRoutesOnlyForTheExactCurrentObserverLinkAndTarget() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let liveReference = await linkReference(fixture)
        let reference = try XCTUnwrap(liveReference)

        let accepted = await fixture.bridge.mutateAutoWakeSnooze(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference,
            command: .set(durationSeconds: 1200),
            origin: .agent
        )
        guard case .success = accepted else {
            return XCTFail("an exact current pairing must reach the owning observer session")
        }
        XCTAssertEqual(fixture.host.snoozeMutationCalls.count, 1)
        let routed = try XCTUnwrap(fixture.host.snoozeMutationCalls.first)
        XCTAssertEqual(routed.endpoint, fixture.observer.domainEndpoint)
        XCTAssertEqual(routed.targetSessionID, fixture.target.sessionID)
        XCTAssertEqual(routed.reference, reference)
        XCTAssertEqual(routed.command, .set(durationSeconds: 1200))
        XCTAssertEqual(routed.origin, .agent)

        // A superseded generation is a different lane, and the target must be the one the reference
        // actually names.
        for stale in [
            DomainAgentSessionLinkReference(
                linkID: reference.linkID,
                generation: reference.generation &+ 1
            ),
            DomainAgentSessionLinkReference(linkID: UUID(), generation: reference.generation)
        ] {
            let refused = await fixture.bridge.mutateAutoWakeSnooze(
                observerEndpoint: fixture.observer.domainEndpoint,
                targetSessionID: fixture.target.sessionID,
                expectedReference: stale,
                command: .clear,
                origin: .user
            )
            XCTAssertEqual(snoozeFailure(refused), .staleReference)
        }
        let wrongTarget = await fixture.bridge.mutateAutoWakeSnooze(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.observer.sessionID,
            expectedReference: reference,
            command: .clear,
            origin: .user
        )
        XCTAssertEqual(snoozeFailure(wrongTarget), .staleReference)

        // An in-place rebind keeps the session UUID while advancing the endpoint's generations.
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.observer.windowID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            sessionID: fixture.observer.sessionID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration &+ 1
        )
        let rebound = await fixture.bridge.mutateAutoWakeSnooze(
            observerEndpoint: superseded,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference,
            command: .clear,
            origin: .user
        )
        XCTAssertEqual(snoozeFailure(rebound), .observerUnavailable)

        XCTAssertEqual(
            fixture.host.snoozeMutationCalls.count,
            1,
            "every refusal is decided at the bridge; none of them reached a session"
        )
    }

    /// The read is routed under the identical fence and stays observational.
    func testAutoWakeSnoozeProjectionIsRoutedAndRefusedAfterRevocationOrFreeze() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let liveReference = await linkReference(fixture)
        let reference = try XCTUnwrap(liveReference)
        let expected = AgentSessionLinkAutoWakeSnoozeProjection(
            expiresAt: Date(timeIntervalSince1970: 2000),
            remainingSeconds: 540,
            origin: .user
        )
        fixture.host.snoozeProjectionResult = .success(expected)

        let read = await fixture.bridge.autoWakeSnoozeProjection(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        guard case let .success(projection) = read else {
            return XCTFail("an exact current pairing must reach the owning observer session")
        }
        XCTAssertEqual(projection, expected)
        XCTAssertEqual(fixture.host.snoozeProjectionCalls.count, 1)

        // A revoked link has no current generation to speak for, in either direction.
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        let afterRevocation = await fixture.bridge.autoWakeSnoozeProjection(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        XCTAssertEqual(snoozeFailure(afterRevocation), .staleReference)
        let mutationAfterRevocation = await fixture.bridge.mutateAutoWakeSnooze(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference,
            command: .clear,
            origin: .user
        )
        XCTAssertEqual(snoozeFailure(mutationAfterRevocation), .staleReference)

        fixture.bridge.freezeForTermination()
        let afterFreeze = await fixture.bridge.autoWakeSnoozeProjection(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: reference
        )
        XCTAssertEqual(snoozeFailure(afterFreeze), .shuttingDown)
        XCTAssertEqual(fixture.host.snoozeProjectionCalls.count, 1)
    }

    private func snoozeFailure(
        _ result: Result<some Any, AgentSessionLinkAutoWakeSnoozeFailure>
    ) -> AgentSessionLinkAutoWakeSnoozeFailure? {
        guard case let .failure(failure) = result else { return nil }
        return failure
    }

    // MARK: - Unlink and fresh-link recovery

    /// Undo restores the Auto-wake selection from the *observer's* saved set, whichever row it was
    /// offered on.
    ///
    /// An inbound Unlink is presented on the overseen session's row, and that session's projection
    /// carries its own selections rather than its observer's. Basing recovery on the invoking props
    /// would write the wrong session's set back onto the observer, so both directions resolve the
    /// observer by session ID instead.
    func testRestoringAnUndoneSelectionUnionsOntoTheObserversOwnSavedSet() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        let unrelatedTarget = UUID()
        fixture.host.autoWakeTargetsByEndpoint[fixture.observer.domainEndpoint] = [unrelatedTarget]
        // Decoy: the overseen session's own selection must never become the union's base.
        let decoy = UUID()
        fixture.host.autoWakeTargetsByEndpoint[fixture.target.domainEndpoint] = [decoy]

        XCTAssertFalse(
            fixture.bridge.autoWakeTargetSelection(observerSessionID: fixture.observer.sessionID)
                .contains(fixture.target.sessionID),
            "a permanent unlink leaves the observer without this target selected"
        )

        let outcome = await fixture.bridge.restoreAutoWakeTargetSelection(
            targetSessionID: fixture.target.sessionID,
            observerSessionID: fixture.observer.sessionID
        )
        guard case .changed = outcome else {
            return XCTFail("expected the restore to change the observer's saved selection")
        }
        XCTAssertEqual(
            fixture.host.autoWakeTargetsByEndpoint[fixture.observer.domainEndpoint],
            [unrelatedTarget, fixture.target.sessionID],
            "the restore is additive against the observer's current set"
        )
        XCTAssertEqual(
            fixture.host.autoWakeTargetsByEndpoint[fixture.target.domainEndpoint],
            [decoy],
            "the overseen session's own selection is neither read as the base nor written"
        )
    }

    /// The dashboard's Undo is not a restoration API: it runs the ordinary Add with the captured
    /// session pair, so the recovered relationship is a new link that inherits nothing.
    func testUnlinkThenUndoStyleReAddCreatesAFreshLinkCarryingNoSeenState() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture),
              let oldReference = await linkReference(fixture)
        else { return XCTFail("missing active link") }

        await publishTargetActivity(fixture, status: .running, activity: 200)
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, true)

        func stop() async -> AgentMonitorStopOutcome {
            await fixture.bridge.stopMonitorLink(
                observerSessionID: fixture.observer.sessionID,
                targetSessionID: fixture.target.sessionID,
                linkID: oldReference.linkID,
                generation: oldReference.generation
            )
        }

        // Revocation is immediate and complete before any recovery is offered.
        let stopped = await stop()
        XCTAssertEqual(stopped, .stopped)
        XCTAssertEqual(fixture.host.publishedProps[fixture.observer.sessionID]?.outbound.isEmpty, true)
        let clearedReference = await linkReference(fixture)
        XCTAssertNil(clearedReference)

        // `.alreadyStopped` does not prove *this* action performed the removal, which is exactly why
        // the dashboard offers no recovery for it.
        let repeatedStop = await stop()
        XCTAssertEqual(repeatedStop, .alreadyStopped)

        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        ), let newReference = await linkReference(fixture) else {
            return XCTFail("undo-style re-add failed")
        }
        XCTAssertNotEqual(newReference, oldReference)

        let recovered = outboundRow(fixture)
        XCTAssertEqual(
            recovered?.hasUnreadActivity,
            false,
            "a fresh link baselines current activity instead of inheriting the retired one's state"
        )
        XCTAssertEqual(recovered?.lastActivityAt, Date(timeIntervalSince1970: 200))

        // Seen addressed to the retired reference cannot reach the replacement.
        guard case .failed = await fixture.bridge.markMonitorActivitySeen(
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID,
            expectedReference: oldReference
        ) else {
            return XCTFail("a retired reference unexpectedly acknowledged the replacement link")
        }
        XCTAssertEqual(outboundRow(fixture)?.hasUnreadActivity, false)
    }

    /// Regression: closing a *duplicate* incarnation's tab must not revoke the granted one's link.
    ///
    /// The `sessions` teardown hook used to escalate one removed tab to a UUID-wide
    /// `invalidateSession`, so an unrelated window closing a tab that merely reused the same session
    /// UUID revoked a grant the user had authorized elsewhere.
    func testClosingADuplicateIncarnationsTabLeavesTheGrantedLinkIntact() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Another window opens the same observer session UUID as its own incarnation, holding no
        // grant of its own.
        let duplicate = makeCandidate(
            windowID: fixture.observer.windowID + 10,
            sessionID: fixture.observer.sessionID,
            displayName: "Planning (duplicate)"
        )
        fixture.host.candidates = [fixture.observer, fixture.target, duplicate]
        await fixture.bridge.test_settleProjections()

        // The duplicate's tab closes. Its endpoint is gone; the granted one is untouched.
        fixture.host.candidates = [fixture.observer, fixture.target]
        await fixture.bridge.invalidateBinding(
            windowID: duplicate.windowID,
            tabID: duplicate.tabID,
            reason: .tabClosed
        )

        let activeLinks = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(activeLinks, 1, "an ungranted duplicate's teardown must revoke nothing")
        let granted = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertNotNil(granted.success, "the authorized incarnation still holds its grant")
    }

    /// The tab-close hook is `(window, tab)`-scoped: it revokes only that incarnation's grants.
    func testTabCloseRevokesOnlyThatWindowAndTabsIncarnation() async {
        let fixture = makeFixture()
        let otherObserver = makeCandidate(windowID: 7, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, otherObserver]

        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: otherObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        ) else { return XCTFail("second add failed") }

        // Only the first observer's tab goes away.
        fixture.host.candidates = [fixture.target, otherObserver]
        await fixture.bridge.invalidateBinding(
            windowID: fixture.observer.windowID,
            tabID: fixture.observer.tabID,
            reason: .tabClosed
        )

        let survivors = await fixture.authority.links(forTarget: fixture.target.sessionID)
        XCTAssertEqual(
            survivors.items.map(\.observerSessionID),
            [otherObserver.sessionID],
            "an unrelated window's grant on the same target must survive"
        )
        let notices = await fixture.authority.recentRevocationNotices(
            forEndpoint: fixture.observer.domainEndpoint
        )
        XCTAssertEqual(notices.first?.reason, .tabClosed)
    }

    func testTargetIdentityDriftRevokesInsteadOfPublishing() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Same session ID, new binding generation: a different incarnation that must never inherit
        // the existing grant.
        let rebound = makeCandidate(
            windowID: fixture.target.windowID,
            sessionID: fixture.target.sessionID,
            workspaceID: fixture.target.workspaceID,
            tabID: fixture.target.tabID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: fixture.target.bindingTransitionGeneration
        )
        fixture.host.candidates = [fixture.observer, rebound]
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let observed8 = await pollState(fixture)
        XCTAssertNil(observed8)
        let observed9 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed9, 0)
    }

    // MARK: - Revocation and projections

    func testAddPublishesProjectionsAtBothEndpoints() async throws {
        let fixture = makeFixture()
        guard case let .added(linkID, _) = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()

        let observerProps = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID])
        XCTAssertEqual(observerProps.outbound.map(\.linkID), [linkID])
        XCTAssertEqual(observerProps.outbound.first?.displayName, "Build API")
        XCTAssertEqual(observerProps.outbound.first?.status, .idle)
        XCTAssertTrue(observerProps.inbound.isEmpty)
        XCTAssertTrue(observerProps.isOverseer)
        XCTAssertNil(observerProps.canAddReason)

        let targetProps = try XCTUnwrap(fixture.host.publishedProps[fixture.target.sessionID])
        XCTAssertEqual(targetProps.inbound.map(\.linkID), [linkID])
        XCTAssertEqual(targetProps.inbound.first?.displayName, "Planning")
        XCTAssertTrue(targetProps.outbound.isEmpty)
        XCTAssertTrue(targetProps.hasInbound)
    }

    func testRevokeClearsBothProjectionsAndLeavesEndpointRelativeNotices() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        await fixture.bridge.test_settleProjections()

        let observerProps = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID])
        let targetProps = try XCTUnwrap(fixture.host.publishedProps[fixture.target.sessionID])
        XCTAssertTrue(observerProps.outbound.isEmpty)
        XCTAssertTrue(targetProps.inbound.isEmpty)
        XCTAssertEqual(observerProps.recentNotices.first?.message, "Oversight of Build API ended: the relationship was unlinked.")
        XCTAssertEqual(
            targetProps.recentNotices.first?.message,
            "Planning no longer oversees this session: the relationship was unlinked."
        )
        let observed10 = await pollState(fixture)
        XCTAssertNil(observed10)
    }

    func testRevokedGenerationNeverResurrects() async {
        let fixture = makeFixture()
        guard case let .added(linkID, _) = await addLink(fixture) else { return XCTFail("add failed") }
        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)

        // A second revoke of the same generation is a no-op, and re-adding mints a new link.
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        guard case let .added(newLinkID, _) = await addLink(fixture) else { return XCTFail("re-add failed") }
        XCTAssertNotEqual(newLinkID, linkID)
        let observed11 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed11, 1)
    }

    // MARK: - Lifecycle invalidation

    func testWindowCloseRevokesLinksAndTearsDownObservation() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        fixture.host.candidates = [fixture.observer]
        await fixture.bridge.invalidateWindow(fixture.target.windowID, reason: .windowClosed)

        let observed12 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed12, 0)
        let observed13 = await fixture.authority.snapshot().observedTargetCount
        XCTAssertEqual(observed13, 0)
        XCTAssertNil(fixture.host.liveObservations[fixture.target.sessionID])
    }

    func testWorkspaceSwitchRevokesOnlyThatWindowsLinks() async {
        let fixture = makeFixture()
        let thirdObserver = makeCandidate(
            windowID: 3,
            workspaceID: fixture.target.workspaceID,
            displayName: "Docs"
        )
        fixture.host.candidates = [fixture.observer, fixture.target, thirdObserver]
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: thirdObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed") }

        // Window 1 switches away; window 3 stays on the same workspace and keeps its link.
        await fixture.bridge.invalidateWorkspace(
            fixture.observer.workspaceID,
            windowID: fixture.observer.windowID,
            reason: .workspaceSwitched
        )

        let observed14 = await pollState(fixture)
        XCTAssertNil(observed14)
        let observed15 = await pollState(fixture, observer: thirdObserver)
        XCTAssertNotNil(observed15)
    }

    func testSessionDeletionRevokesEveryIncarnation() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        fixture.host.candidates = [fixture.observer]
        await fixture.bridge.invalidateSession(fixture.target.sessionID, reason: .sessionDeleted)
        let observed16 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed16, 0)
    }

    func testLazySweepRevokesEndpointsThatDisappearedWithoutAnEagerHook() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // No lifecycle hook fires: the observer's window simply stops reporting the endpoint.
        fixture.host.candidates = [fixture.target]
        await fixture.bridge.revalidateLiveEndpoints()

        let observed17 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed17, 0)
        let observed18 = await pollState(fixture)
        XCTAssertNil(observed18)
    }

    // MARK: - Incarnation-scoped teardown (audit issue 3)

    func testSweepingAStaleIncarnationNeverTearsDownTheNewerChainForTheSameSessionUUID() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        let staleTargetEndpoint = fixture.target.domainEndpoint

        // The target rebinds in place: same session UUID, new incarnation E2. The observer re-adds,
        // so E2 owns a live chain while E1 is still remembered.
        let rebound = makeCandidate(
            windowID: fixture.target.windowID,
            sessionID: fixture.target.sessionID,
            workspaceID: fixture.target.workspaceID,
            tabID: fixture.target.tabID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: fixture.target.bindingTransitionGeneration &+ 1,
            displayName: "Build API"
        )
        fixture.host.candidates = [fixture.observer, rebound]
        await fixture.bridge.invalidate(endpoint: staleTargetEndpoint, reason: .targetIdentityDrift)
        guard case .added = await addLink(fixture) else { return XCTFail("re-add failed") }
        XCTAssertNotNil(fixture.host.liveObservations[fixture.target.sessionID])

        // A later sweep must not act on E1 at all: it was pruned on revocation, and teardown is
        // incarnation-scoped even if it had not been.
        await fixture.bridge.revalidateLiveEndpoints()

        XCTAssertNotNil(
            fixture.host.liveObservations[fixture.target.sessionID],
            "stale incarnation tore down the live chain for the same session UUID"
        )
        let state = await pollState(fixture)
        XCTAssertNotNil(state, "live link revoked by a stale incarnation sweep")
    }

    // MARK: - Snapshot dedupe (audit issue 4)

    func testIdenticalRepublicationsDoNotAdvanceChangeSequence() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        let rawSeeded = await pollState(fixture)
        let seeded = try XCTUnwrap(rawSeeded)

        // Simulates the replay burst every new `@Published` subscription emits: many wakes, no state
        // change. None of them may advance `change_sequence` or wake a parked waiter.
        for _ in 0 ..< 5 {
            fixture.host.fireObservation(for: fixture.target.sessionID)
        }
        await fixture.bridge.test_settleProjections()

        let rawAfter = await pollState(fixture)
        let after = try XCTUnwrap(rawAfter)
        XCTAssertEqual(after.changeSequence, seeded.changeSequence)

        // A real change still gets through.
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: "working",
            visibleRowCount: 5,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        let rawChanged = await pollState(fixture)
        let changed = try XCTUnwrap(rawChanged)
        XCTAssertEqual(changed.snapshot.status, .running)
        XCTAssertGreaterThan(changed.changeSequence, seeded.changeSequence)
    }

    // MARK: - Observer-side binding changes (audit issue 2)

    func testObserverRebindRevokesItsOutboundLink() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // The observer tab stays alive but rebinds to a different session: `sessions.didSet` sees no
        // removal, so only the binding seam can catch this.
        let rebound = makeCandidate(
            windowID: fixture.observer.windowID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            displayName: "Planning"
        )
        fixture.host.candidates = [rebound, fixture.target]
        await fixture.bridge.invalidateBinding(
            windowID: fixture.observer.windowID,
            tabID: fixture.observer.tabID
        )

        let state = await pollState(fixture)
        XCTAssertNil(state)
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
        XCTAssertEqual(snapshot.observedTargetCount, 0)
        XCTAssertNil(fixture.host.liveObservations[fixture.target.sessionID])
    }

    func testObserverBindingGenerationChangeAloneRevokes() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        // Same session UUID, new persistent binding generation: a different incarnation that must not
        // inherit the grant.
        let rebound = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: UUID(),
            displayName: "Planning"
        )
        fixture.host.candidates = [rebound, fixture.target]
        await fixture.bridge.invalidateBinding(
            windowID: fixture.observer.windowID,
            tabID: fixture.observer.tabID
        )

        let state = await pollState(fixture)
        XCTAssertNil(state)
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.activeLinkCount, 0)
    }

    func testBindingChangeInOneWindowLeavesAnotherWindowsLinkToTheSameTargetIntact() async {
        let fixture = makeFixture()
        let otherObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, otherObserver]
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: otherObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed") }

        let reboundObserver = makeCandidate(
            windowID: fixture.observer.windowID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            displayName: "Planning"
        )
        fixture.host.candidates = [reboundObserver, fixture.target, otherObserver]
        await fixture.bridge.invalidateBinding(
            windowID: fixture.observer.windowID,
            tabID: fixture.observer.tabID
        )

        let revoked = await pollState(fixture)
        XCTAssertNil(revoked)
        let survivor = await pollState(fixture, observer: otherObserver)
        XCTAssertNotNil(survivor, "an unrelated window's link was revoked by a binding change")
        // The target's observation must survive because an inbound link remains.
        XCTAssertNotNil(fixture.host.liveObservations[fixture.target.sessionID])
    }

    func testBindingChangeForAnUnrelatedTabIsANoOp() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.invalidateBinding(windowID: 99, tabID: UUID())
        let state = await pollState(fixture)
        XCTAssertNotNil(state)
    }

    // MARK: - Observer rejection messages (audit issue 6)

    func testObserverLifecycleReasonsStaySpecificWhileRoleDenialStaysGeneric() async {
        let loading = makeFixture()
        loading.host.candidates = [
            makeCandidate(
                windowID: loading.observer.windowID,
                sessionID: loading.observer.sessionID,
                workspaceID: loading.observer.workspaceID,
                tabID: loading.observer.tabID,
                persistentBindingGeneration: loading.observer.persistentBindingGeneration ?? UUID(),
                bindingTransitionGeneration: loading.observer.bindingTransitionGeneration,
                hasLoadedPersistedState: false
            ),
            loading.target
        ]
        let loadingOutcome = await addLink(loading)
        XCTAssertEqual(loadingOutcome, .rejected(message: AgentSessionLinkResolveFailure.loading.uiMessage))

        let rebinding = makeFixture()
        rebinding.host.candidates = [
            makeCandidate(
                windowID: rebinding.observer.windowID,
                sessionID: rebinding.observer.sessionID,
                workspaceID: rebinding.observer.workspaceID,
                tabID: rebinding.observer.tabID,
                persistentBindingGeneration: rebinding.observer.persistentBindingGeneration ?? UUID(),
                bindingTransitionGeneration: rebinding.observer.bindingTransitionGeneration,
                bindingTransitionInProgress: true
            ),
            rebinding.target
        ]
        let rebindingOutcome = await addLink(rebinding)
        XCTAssertEqual(rebindingOutcome, .rejected(message: AgentSessionLinkResolveFailure.rebinding.uiMessage))

        // A child observer must not learn *why* it was refused beyond the generic role sentence.
        let child = makeFixture()
        child.host.candidates = [
            makeCandidate(
                windowID: child.observer.windowID,
                sessionID: child.observer.sessionID,
                workspaceID: child.observer.workspaceID,
                tabID: child.observer.tabID,
                persistentBindingGeneration: child.observer.persistentBindingGeneration ?? UUID(),
                bindingTransitionGeneration: child.observer.bindingTransitionGeneration,
                isTopLevel: false
            ),
            child.target
        ]
        let childOutcome = await addLink(child)
        XCTAssertEqual(childOutcome, .rejected(message: AgentSessionLinkEndpointEligibility.roleDeniedReason))

        // An observer with no live binding at all is indistinguishable from a role denial.
        let absent = makeFixture()
        absent.host.candidates = [absent.target]
        let absentOutcome = await addLink(absent)
        XCTAssertEqual(absentOutcome, .rejected(message: AgentSessionLinkEndpointEligibility.roleDeniedReason))
    }

    // MARK: - Preview

    func testResolvePreviewDoesNotGrantAnything() async {
        let fixture = makeFixture()
        let preview = fixture.bridge.resolvePreview(
            observerSessionID: fixture.observer.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString,
            existingOutboundTargetIDs: []
        )
        guard case let .success(resolved) = preview else { return XCTFail("preview failed") }
        XCTAssertEqual(resolved.displayName, "Build API")
        XCTAssertEqual(resolved.status, .idle)
        XCTAssertEqual(resolved.fullID, fixture.target.sessionID.uuidString)

        // Knowing and resolving a UUID is never authority.
        let observed19 = await pollState(fixture)
        XCTAssertNil(observed19)
        let observed20 = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(observed20, 0)
    }

    func testPreviewReportsSelfAndDuplicateBeforeResolution() {
        let fixture = makeFixture()
        XCTAssertEqual(
            fixture.bridge.resolvePreview(
                observerSessionID: fixture.observer.sessionID,
                rawTargetSessionID: fixture.observer.sessionID.uuidString,
                existingOutboundTargetIDs: []
            ).failure,
            .selfMonitor
        )
        XCTAssertEqual(
            fixture.bridge.resolvePreview(
                observerSessionID: fixture.observer.sessionID,
                rawTargetSessionID: fixture.target.sessionID.uuidString,
                existingOutboundTargetIDs: [fixture.target.sessionID]
            ).failure,
            .alreadyMonitoring
        )
    }

    func testPreviewReportsUnavailableStatusForAnUnresolvableTarget() {
        let fixture = makeFixture()
        XCTAssertEqual(
            fixture.bridge.resolvePreview(
                observerSessionID: fixture.observer.sessionID,
                rawTargetSessionID: UUID().uuidString,
                existingOutboundTargetIDs: []
            ).failure,
            .notFound
        )
    }

    // MARK: - Status projection cost

    func testMonitorRowStatusUsesTheNarrowProjectionAndNeverTheFullSnapshot() async {
        let fixture = makeFixture()
        // Three outbound rows: the old path built one full snapshot per row per refresh.
        let extraTargets = (0 ..< 2).map { makeCandidate(windowID: 10 + $0, displayName: "Target \($0)") }
        fixture.host.candidates.append(contentsOf: extraTargets)
        _ = await addLink(fixture)
        for target in extraTargets {
            _ = await fixture.bridge.addMonitorLink(
                observerSessionID: fixture.observer.sessionID,
                rawTargetSessionID: target.sessionID.uuidString
            )
        }
        await fixture.bridge.test_settleProjections()

        let observer = fixture.observer.sessionID
        XCTAssertEqual(fixture.host.publishedProps[observer]?.outbound.count, 3)

        let snapshotsBefore = fixture.host.observationSnapshotCalls
        let statusBefore = fixture.host.statusProjectionCalls[fixture.target.sessionID] ?? 0

        await fixture.bridge.revalidateLiveEndpoints()

        // Row *rendering* still reads only the narrow projection. The authoritative pass does build
        // one observation snapshot per outbound target, because the lane sample carries the redacted
        // preview and send readiness the row knows nothing about — but it must never build more than
        // one per target per pass, and the presentation-only repaint below builds none.
        let snapshotDelta = fixture.host.observationSnapshotCalls.reduce(into: 0) { total, entry in
            total += entry.value - (snapshotsBefore[entry.key] ?? 0)
        }
        XCTAssertLessThanOrEqual(
            snapshotDelta,
            3,
            "one observation snapshot per outbound target per authoritative pass, and no more"
        )
        XCTAssertGreaterThan(
            fixture.host.statusProjectionCalls[fixture.target.sessionID] ?? 0,
            statusBefore,
            "Oversee rows must read status through the narrow projection"
        )
    }

    func testTargetPublicationStillUsesTheFullRedactedSnapshot() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let before = fixture.host.observationSnapshotCalls[fixture.target.sessionID] ?? 0

        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: "streaming",
            visibleRowCount: 4,
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()

        // The agent-facing path is unchanged: `poll` still receives the redacted preview.
        XCTAssertGreaterThan(fixture.host.observationSnapshotCalls[fixture.target.sessionID] ?? 0, before)
        let state = await pollState(fixture)
        XCTAssertEqual(state?.snapshot.latestVisibleAssistantPreview, "streaming")
        XCTAssertEqual(state?.snapshot.status, .running)
    }

    // MARK: - Operation-time observer capability

    /// Same endpoint incarnation, different capability: the identity check alone cannot see this.
    private func replaceObserver(
        _ fixture: Fixture,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        roleAllowsOutboundMonitoring: Bool = true,
        bindingTransitionInProgress: Bool = false
    ) {
        let mutated = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration ?? UUID(),
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            roleAllowsOutboundMonitoring: roleAllowsOutboundMonitoring,
            displayName: fixture.observer.displayName ?? "Planning"
        )
        XCTAssertEqual(
            mutated.domainEndpoint,
            fixture.observer.domainEndpoint,
            "The capability change must not move the endpoint incarnation, or the test proves nothing"
        )
        fixture.host.candidates = fixture.host.candidates.map {
            $0.sessionID == fixture.observer.sessionID ? mutated : $0
        }
    }

    func testObserverCapturedByExternalMCPControlLosesItsGrantAtOperationTime() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        var authorized = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertNotNil(authorized.success)

        replaceObserver(fixture, isMCPControlled: true)

        authorized = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertEqual(authorized.failure, .denied)
        // Atomically revoked, not merely denied: a later retry must not find the grant intact.
        let outbound = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(outbound.isEmpty)
    }

    func testRoleDeniedObserverLosesItsGrantAtOperationTime() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        replaceObserver(fixture, roleAllowsOutboundMonitoring: false)

        let authorized = await fixture.bridge.authorizeTarget(
            operation: .monitorRead,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertEqual(authorized.failure, .denied)
        let outbound = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(outbound.isEmpty)
    }

    func testDisqualifiedObserverIncarnationDoesNotRevokeLiveSiblingGrants() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else {
            return XCTFail("first exact observer link was not created")
        }
        let siblingObserver = makeCandidate(
            windowID: 3,
            sessionID: fixture.observer.sessionID,
            displayName: "Planning sibling"
        )
        let siblingTarget = makeCandidate(windowID: 4, displayName: "Sibling target")
        fixture.host.candidates.append(contentsOf: [siblingObserver, siblingTarget])
        guard case .added = await fixture.bridge.addMonitorLink(
            observerEndpoint: siblingObserver.domainEndpoint,
            targetEndpoint: siblingTarget.domainEndpoint
        ) else {
            return XCTFail("sibling exact observer link was not created")
        }

        let disqualified = makeCandidate(
            windowID: fixture.observer.windowID,
            sessionID: fixture.observer.sessionID,
            workspaceID: fixture.observer.workspaceID,
            tabID: fixture.observer.tabID,
            persistentBindingGeneration: fixture.observer.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.observer.bindingTransitionGeneration,
            roleAllowsOutboundMonitoring: false,
            displayName: fixture.observer.displayName ?? "Planning"
        )
        fixture.host.candidates = fixture.host.candidates.map {
            $0.domainEndpoint == fixture.observer.domainEndpoint ? disqualified : $0
        }

        let denied = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertEqual(denied.failure, .denied)
        let disqualifiedInventory = await fixture.authority.links(
            forObserverEndpoint: fixture.observer.domainEndpoint
        )
        let siblingInventory = await fixture.authority.links(
            forObserverEndpoint: siblingObserver.domainEndpoint
        )
        XCTAssertTrue(disqualifiedInventory.isEmpty)
        XCTAssertEqual(
            siblingInventory.items.map(\.targetSessionID),
            [siblingTarget.sessionID],
            "one disqualified incarnation must not revoke another exact incarnation's grants"
        )
    }

    func testTargetlessListIsAlsoReCheckedAgainstObserverCapability() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let granted = await fixture.bridge.inventory(forObserverEndpoint: fixture.observer.domainEndpoint)
        XCTAssertNotNil(granted.success)

        replaceObserver(fixture, isMCPOriginated: true)

        // `list` presents no per-target proof, so it needs its own re-check or it stays callable.
        let denied = await fixture.bridge.inventory(forObserverEndpoint: fixture.observer.domainEndpoint)
        XCTAssertEqual(denied.failure, .denied)
        let outbound = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(outbound.isEmpty)
    }

    func testMomentaryObserverStateDeniesButKeepsTheGrant() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        replaceObserver(fixture, bindingTransitionInProgress: true)

        let denied = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertEqual(denied.failure, .denied)
        let outbound = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertFalse(outbound.isEmpty, "A rebinding observer must not lose a healthy link")

        // Settling restores access without re-adding.
        replaceObserver(fixture)
        let restored = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        XCTAssertNotNil(restored.success)
    }

    func testLosingOutboundCapabilityKeepsTheSessionMonitorableByOthers() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)

        // A third session monitors our observer. Being observed requires no outbound eligibility.
        let watcher = makeCandidate(windowID: 3, displayName: "Watcher")
        fixture.host.candidates.append(watcher)
        let inboundAdd = await fixture.bridge.addMonitorLink(
            observerSessionID: watcher.sessionID,
            rawTargetSessionID: fixture.observer.sessionID.uuidString
        )
        guard case .added = inboundAdd else {
            return XCTFail("Expected the watcher link to be created, got \(inboundAdd)")
        }

        replaceObserver(fixture, isMCPControlled: true)
        _ = await fixture.bridge.authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )

        let outbound = await fixture.authority.links(forObserver: fixture.observer.sessionID)
        XCTAssertTrue(outbound.isEmpty, "Outbound oversight must end")
        let inbound = await fixture.authority.links(forTarget: fixture.observer.sessionID)
        XCTAssertEqual(
            inbound.items.map(\.observerSessionID),
            [watcher.sessionID],
            "Losing the ability to oversee must not stop the session from being overseen"
        )
    }

    // MARK: - Atomic idle-only send

    private func authorizedSendTarget(
        _ fixture: Fixture
    ) async -> AgentSessionLinkRuntimeBridge.AuthorizedTarget? {
        await fixture.bridge.authorizeTarget(
            operation: .monitorSend,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        ).success
    }

    private func delivered(
        state: DomainAgentSessionLinkDeliveryState = .runStarted,
        runState: String = "running"
    ) -> AgentSessionLinkSendTransactionOutcome {
        .delivered(AgentSessionLinkSendDelivery(
            targetItemID: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 2000),
            deliveryState: state,
            resultingRunState: runState
        ))
    }

    /// The observer's live candidate supplies identity and the badge name — and nothing else.
    ///
    /// The user's exact direct grant is the delegation, so a send carries no proof about what started
    /// the caller's own turn. What must still hold is that every delivery is structurally attributed
    /// to the exact granted incarnation, which is what stops an observer from speaking anonymously.
    func testSendPassesObserverIdentityAndNameToTheTargetTransactionWithNoCallerTurnProof() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageReadyTarget(fixture)

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        let outcome = await fixture.bridge.send(
            target: target,
            message: "ship it",
            idempotencyKey: "key-1"
        )

        guard case .receipt = outcome else {
            return XCTFail("A grant-authorized send into an idle target must deliver: \(outcome)")
        }
        let request = try XCTUnwrap(fixture.host.sendRequests.first?.request)
        XCTAssertEqual(request.observerSessionID, fixture.observer.sessionID)
        XCTAssertEqual(request.observerDisplayName, "Planning")
        XCTAssertEqual(request.message, "ship it")
        XCTAssertEqual(request.attribution.sourceSessionID, fixture.observer.sessionID)
        XCTAssertEqual(request.attribution.linkID, target.lease.linkID)
    }

    func testDeliveredSendRetainsAStableReceiptAndReplaysItForADuplicateRetry() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let itemID = UUID()
        fixture.host.sendOutcome = .delivered(AgentSessionLinkSendDelivery(
            targetItemID: itemID,
            acceptedAt: Date(timeIntervalSince1970: 2000),
            deliveryState: .runStarted,
            resultingRunState: "running"
        ))

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        guard case let .receipt(first) = await fixture.bridge.send(
            target: target,
            message: "ship it",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected a delivery receipt") }
        XCTAssertEqual(first.targetItemID, itemID.uuidString)
        XCTAssertEqual(first.deliveryState, .runStarted)
        XCTAssertFalse(first.duplicate)

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        guard case let .receipt(replay) = await fixture.bridge.send(
            target: retryTarget,
            message: "ship it",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected the stored receipt to replay") }
        XCTAssertTrue(replay.duplicate)
        XCTAssertEqual(replay.targetItemID, first.targetItemID)
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "A duplicate retry must never reach the target transaction again"
        )
    }

    func testSameKeyWithDifferentTextConflictsAndDeliversNothing() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered()

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        _ = await fixture.bridge.send(target: target, message: "first", idempotencyKey: "key-1")

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        let conflict = await fixture.bridge.send(
            target: retryTarget,
            message: "second",
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(conflict, .rejected(.idempotencyConflict))
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "A conflicting key must deliver neither the new nor the old payload"
        )
    }

    func testIntentionallyRepeatedMessageIsDeliverableUnderANewKey() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered()

        for key in ["key-1", "key-2"] {
            let resolvedTarget = await authorizedSendTarget(fixture)
            let target = try XCTUnwrap(resolvedTarget)
            guard case .receipt = await fixture.bridge.send(
                target: target,
                message: "status?",
                idempotencyKey: key
            ) else { return XCTFail("Expected \(key) to deliver") }
        }
        XCTAssertEqual(fixture.host.sendRequests.count, 2)
    }

    /// Revocation that wins the commit fence must leave the target untouched. The fake host runs the
    /// real fence, so this exercises the same ordering production uses.
    func testManualRevocationBeforeTheCommitFenceCancelsWithoutMutatingTheTarget() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let resolvedReference = await linkReference(fixture)
        let reference = try XCTUnwrap(resolvedReference)
        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        fixture.host.sendOutcome = delivered()
        fixture.host.invokesSendCommit = true
        // Revoke inside the reservation-to-commit window: the fence, not the pre-reservation lease
        // check, has to be what refuses.
        fixture.host.beforeSendCommit = { [authority = fixture.authority] in
            _ = await authority.revoke(
                linkID: reference.linkID,
                generation: reference.generation,
                reason: .userRequested
            )
        }

        let outcome = await fixture.bridge.send(
            target: target,
            message: "too late",
            idempotencyKey: "key-1"
        )

        XCTAssertEqual(outcome, .blocked(.linkRevoked))
        XCTAssertEqual(fixture.host.sendCommitOutcomes, [.linkRevoked])
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0)
        XCTAssertEqual(
            snapshot.retainedSendOutcomeCount,
            0,
            "A send cancelled at the fence must retain no receipt to replay."
        )
    }

    /// Winning the fence lets an already-authorized send settle even though Stop follows, and the
    /// stored receipt survives only as long as its generation can still be referenced.
    func testCommitBeforeManualRevocationSettlesExactlyOnce() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let resolvedReference = await linkReference(fixture)
        let reference = try XCTUnwrap(resolvedReference)
        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        fixture.host.sendOutcome = delivered()

        guard case .receipt = await fixture.bridge.send(
            target: target,
            message: "in time",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected the committed send to settle") }

        _ = await fixture.authority.revoke(
            linkID: reference.linkID,
            generation: reference.generation,
            reason: .userRequested
        )
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0)
        XCTAssertEqual(
            snapshot.retainedSendOutcomeCount,
            0,
            "Revocation releases the ledger slots owned by that generation"
        )
    }

    /// A refusal must not burn the key: the observer fixes the target's state and retries.
    func testBlockedSendReleasesTheReservationSoTheSameKeyCanRetry() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = .blocked(.targetNotIdle)

        let resolvedBusyTarget = await authorizedSendTarget(fixture)
        let busyTarget = try XCTUnwrap(resolvedBusyTarget)
        let busyOutcome = await fixture.bridge.send(
            target: busyTarget,
            message: "now?",
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(busyOutcome, .blocked(.targetNotIdle))
        let inFlight = await fixture.authority.snapshot().inFlightSendCount
        XCTAssertEqual(inFlight, 0, "A refused send must not hold a ledger slot")

        fixture.host.sendOutcome = delivered()
        let resolvedIdleTarget = await authorizedSendTarget(fixture)
        let idleTarget = try XCTUnwrap(resolvedIdleTarget)
        guard case .receipt = await fixture.bridge.send(
            target: idleTarget,
            message: "now?",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected the retry to deliver") }
    }

    /// A run start that fails after durable persistence keeps the row and reports the state, so the
    /// observer polls instead of re-delivering.
    func testRunStartFailureAfterDurableAcceptanceStillProducesAStableReceipt() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered(state: .runStartFailed, runState: "failed")

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        guard case let .receipt(receipt) = await fixture.bridge.send(
            target: target,
            message: "go",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected a receipt") }
        XCTAssertEqual(receipt.deliveryState, .runStartFailed)
        XCTAssertEqual(receipt.resultingRunState, "failed")

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        let replayOutcome = await fixture.bridge.send(
            target: retryTarget,
            message: "go",
            idempotencyKey: "key-1"
        )
        guard case let .receipt(replay) = replayOutcome else {
            return XCTFail("Expected the stored run_start_failed receipt to replay")
        }
        XCTAssertTrue(replay.duplicate)
        XCTAssertEqual(replay.deliveryState, .runStartFailed)
        XCTAssertEqual(fixture.host.sendRequests.count, 1)
    }

    // MARK: - Per-message workflow

    /// The ledger has to answer before a workflow is looked up, which is what lets a retry stay
    /// idempotent across a workflow the user renamed or deleted in between.
    ///
    /// Proved through the conflict branch on purpose: the second call names a workflow that cannot
    /// resolve, so `idempotency_conflict` rather than a workflow error is only possible if the digest
    /// was compared first.
    func testWorkflowSelectorBelongsToTheDeliveryIdentityAndIsComparedBeforeResolution() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered()

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        guard case .receipt = await fixture.bridge.send(
            target: target,
            message: "ship it",
            idempotencyKey: "key-1",
            workflowReference: nil
        ) else { return XCTFail("Expected the plain send to deliver") }

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        let conflict = await fixture.bridge.send(
            target: retryTarget,
            message: "ship it",
            idempotencyKey: "key-1",
            workflowReference: .name("A workflow that does not exist \(UUID().uuidString)")
        )

        XCTAssertEqual(
            conflict,
            .rejected(.idempotencyConflict),
            "Same key and text under a different workflow is a different payload, not a retry"
        )
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "A conflicting key must deliver neither payload"
        )
    }

    /// A workflow that stops existing after delivery must not turn a legitimate retry into an error:
    /// the stored receipt is replayed without any lookup at all.
    func testDuplicateRetryReplaysWithoutResolvingAWorkflowThatIsGone() async throws {
        let store = AgentWorkflowStore.shared
        let wasHidden = store.isBuiltInHidden(.deepPlan)
        store.setBuiltInVisibility(.deepPlan, isVisible: true)
        defer { store.setBuiltInVisibility(.deepPlan, isVisible: !wasHidden) }

        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered()
        let reference = AgentWorkflowReference.name(AgentWorkflow.deepPlan.displayName)
        XCTAssertNotNil(reference.resolved(), "precondition: the workflow resolves before delivery")

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        guard case let .receipt(first) = await fixture.bridge.send(
            target: target,
            message: "plan it",
            idempotencyKey: "key-1",
            workflowReference: reference
        ) else { return XCTFail("Expected the workflow send to deliver") }
        XCTAssertFalse(first.duplicate)
        XCTAssertEqual(
            fixture.host.sendRequests.first?.request.workflow,
            AgentWorkflow.deepPlan.definition,
            "The resolved one-shot workflow must reach the target transaction"
        )

        // The workflow disappears between the delivery and the retry.
        store.setBuiltInVisibility(.deepPlan, isVisible: false)
        XCTAssertNil(reference.resolved(), "precondition: the workflow no longer resolves")

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        guard case let .receipt(replay) = await fixture.bridge.send(
            target: retryTarget,
            message: "plan it",
            idempotencyKey: "key-1",
            workflowReference: reference
        ) else { return XCTFail("Expected the stored receipt to replay") }
        XCTAssertTrue(replay.duplicate)
        XCTAssertEqual(replay.targetItemID, first.targetItemID)
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "A duplicate retry must never reach the target transaction again"
        )
    }

    /// A workflow nothing answers to is a caller mistake: nothing is delivered, nothing is staged,
    /// and the key stays free for a corrected retry.
    func testUnresolvableWorkflowRefusesWithoutTouchingTheTargetOrBurningTheKey() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        fixture.host.sendOutcome = delivered()

        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        let outcome = await fixture.bridge.send(
            target: target,
            message: "plan it",
            idempotencyKey: "key-1",
            workflowReference: .id("missing-workflow")
        )

        XCTAssertEqual(outcome, .workflowUnavailable(reference: "missing-workflow"))
        XCTAssertTrue(fixture.host.sendRequests.isEmpty, "Nothing may reach the target transaction")
        let inFlight = await fixture.authority.snapshot().inFlightSendCount
        XCTAssertEqual(inFlight, 0, "The abandoned reservation must not hold a ledger slot")

        let resolvedRetryTarget = await authorizedSendTarget(fixture)
        let retryTarget = try XCTUnwrap(resolvedRetryTarget)
        guard case .receipt = await fixture.bridge.send(
            target: retryTarget,
            message: "plan it",
            idempotencyKey: "key-1"
        ) else { return XCTFail("Expected the corrected retry to deliver under the same key") }
    }

    // MARK: - One pending send per link generation

    /// The queue slot as this observer's own `poll` would report it.
    private func pendingSend(
        _ fixture: Fixture
    ) async -> AgentSessionLinkPendingSendProjection? {
        guard let target = await authorizedSendTarget(fixture) else { return nil }
        return fixture.bridge.pendingSendProjection(for: target.lease)
    }

    /// Lets the bridge's detached drain tasks run.
    ///
    /// Drains are deliberately event-driven and detached — a readiness publication *schedules* one
    /// rather than awaiting it, which is what keeps the design free of timers — so a test has to give
    /// those tasks a turn. Condition-based and bounded rather than a sleep, so it returns the instant
    /// the state settles and cannot pass by waiting long enough.
    private func settleDrains(until condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 500 {
            if await condition() { return }
            await Task.yield()
        }
    }

    /// Mutable capture for a hook that runs inside the send transaction.
    private final class QueueOutcomeBox {
        var value: AgentSessionLinkRuntimeBridge.QueueOutcome?
    }

    private func queueSend(
        _ fixture: Fixture,
        message: String = "ship it",
        key: String = "key-1",
        workflowReference: AgentWorkflowReference? = nil,
        replacePending: Bool = false
    ) async -> AgentSessionLinkRuntimeBridge.QueueOutcome? {
        guard let target = await authorizedSendTarget(fixture) else { return nil }
        return await fixture.bridge.queueSend(
            target: target,
            message: message,
            idempotencyKey: key,
            workflowReference: workflowReference,
            replacePending: replacePending
        )
    }

    /// Models a target that refuses before the authorization fence.
    ///
    /// This is the ordinary busy case, and the fence placement is the point: the real transaction
    /// evaluates readiness at admission and returns long before it commits anything, so the entry is
    /// still cancellable and parks for the next readiness event.
    private func stageBusyTarget(_ fixture: Fixture) {
        fixture.host.invokesSendCommit = false
        fixture.host.sendOutcome = .blocked(.targetNotIdle)
    }

    /// Models a target that accepts, including the commit fence the cancellation cutoff hangs off.
    private func stageReadyTarget(_ fixture: Fixture) {
        fixture.host.invokesSendCommit = true
        fixture.host.sendOutcome = delivered()
    }

    /// `when_sendable` is not a second delivery mechanism: a target that is already ready takes the
    /// message through the ordinary send path, in the same call, with the ordinary receipt.
    func testQueuedSendDeliversImmediatelyWhenTheTargetAlreadyAcceptsIt() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageReadyTarget(fixture)

        let outcome = await queueSend(fixture)

        guard case let .send(.receipt(receipt)) = outcome else {
            return XCTFail("Expected an immediate delivery, got \(String(describing: outcome))")
        }
        XCTAssertFalse(receipt.duplicate)
        XCTAssertEqual(fixture.host.sendRequests.count, 1)
        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending, "A delivered message must leave nothing queued")
        XCTAssertEqual(
            projection?.lastResult?.outcome,
            .delivered(receipt),
            "The terminal outcome stays readable through poll until the next queue mutation"
        )
    }

    /// The field case: the target is busy, so the message waits and lands on the next readiness
    /// publication rather than on a retry loop.
    func testBusyTargetHoldsOneEntryAndDeliversOnTheNextReadinessPublication() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)

        let queued = await queueSend(fixture, message: "review the diff")
        XCTAssertEqual(queued, .queued(replaced: false, duplicate: false))
        let queuedProjection = await pendingSend(fixture)
        let pending = try XCTUnwrap(queuedProjection?.pending)
        XCTAssertEqual(pending.idempotencyKey, "key-1")
        XCTAssertEqual(pending.messagePreview, "review the diff")
        XCTAssertEqual(pending.queuedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertNil(queuedProjection?.lastResult)

        // Nothing is retried until the target actually reports it can take the message.
        stageReadyTarget(fixture)
        XCTAssertEqual(fixture.host.sendRequests.count, 1, "No polling between events")

        await publishTargetActivity(fixture, status: .idle, activity: 2000)
        await settleDrains { fixture.host.sendRequests.count > 1 }
        let projection = await pendingSend(fixture)

        XCTAssertNil(projection?.pending, "The entry must be consumed by the delivery")
        guard case .delivered = try XCTUnwrap(projection?.lastResult?.outcome) else {
            return XCTFail("Expected the retained outcome to be the delivery receipt")
        }
        XCTAssertEqual(projection?.lastResult?.idempotencyKey, "key-1")
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            2,
            "Exactly one redelivery attempt, triggered by the readiness publication"
        )
        XCTAssertEqual(fixture.host.sendRequests.last?.request.message, "review the diff")
    }

    /// Queue admission is decided by the grant and the slot, not by what started the caller's turn.
    ///
    /// The exact granted observer incarnation is still required — a drifted one may not install an
    /// entry — but there is no caller-origin predicate left for admission to consult.
    func testQueueAdmissionIsGrantAuthorizedWithoutAnyCallerTurnProof() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)

        let outcome = await queueSend(fixture)

        XCTAssertEqual(outcome, .queued(replaced: false, duplicate: false))
        let projection = await pendingSend(fixture)
        XCTAssertNotNil(projection?.pending)
    }

    /// A queued entry freezes identity, payload, and workflow — and captures no observer-turn state.
    ///
    /// The drain therefore has nothing about the caller to recapture or compare, and a message the
    /// user asked for cannot be refused merely because of when the target happened to free up.
    func testQueuedDeliveryCapturesNoObserverTurnStateAndDrainsOnReadiness() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        let queued = await queueSend(fixture)
        XCTAssertEqual(queued, .queued(replaced: false, duplicate: false))

        stageReadyTarget(fixture)
        await publishTargetActivity(fixture, status: .idle, activity: 2000)
        await settleDrains { !fixture.host.sendRequests.isEmpty }

        let delivered = try? XCTUnwrap(fixture.host.sendRequests.last?.request)
        XCTAssertEqual(delivered?.observerEndpoint, fixture.observer.domainEndpoint)
        XCTAssertEqual(delivered?.message, "ship it")
        let drained = await pendingSend(fixture)
        XCTAssertNil(drained?.pending)
    }

    /// One slot, and a second key has to say so explicitly.
    func testSecondKeyNeedsReplacePendingAndReplacementSwapsTheEntryAtomically() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        let first = await queueSend(fixture, message: "first", key: "key-1")
        XCTAssertEqual(first, .queued(replaced: false, duplicate: false))

        let occupied = await queueSend(fixture, message: "second", key: "key-2")
        XCTAssertEqual(
            occupied,
            .result(.pendingSendExists),
            "A different key must not silently displace the message already queued"
        )
        let unchanged = await pendingSend(fixture)
        XCTAssertEqual(unchanged?.pending?.idempotencyKey, "key-1")

        let replaced = await queueSend(
            fixture,
            message: "second",
            key: "key-2",
            replacePending: true
        )
        XCTAssertEqual(replaced, .queued(replaced: true, duplicate: false))
        let projection = await pendingSend(fixture)
        let pending = try XCTUnwrap(projection?.pending)
        XCTAssertEqual(pending.idempotencyKey, "key-2")
        XCTAssertEqual(pending.messagePreview, "second")
    }

    /// Same key, same payload is a retry of the entry that already exists; same key, different
    /// payload is a conflict that queues neither.
    func testSameKeyReplaysAndADifferentPayloadUnderThatKeyConflicts() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, message: "first", key: "key-1")

        let replay = await queueSend(fixture, message: "first", key: "key-1")
        XCTAssertEqual(replay, .queued(replaced: false, duplicate: true))
        let conflict = await queueSend(fixture, message: "changed", key: "key-1")
        XCTAssertEqual(conflict, .send(.rejected(.idempotencyConflict)))
        let projection = await pendingSend(fixture)
        let pending = try XCTUnwrap(projection?.pending)
        XCTAssertEqual(
            pending.messagePreview,
            "first",
            "A conflicting call must leave the queued message exactly as it was"
        )
    }

    /// A same-key retry must not re-resolve anything: the entry already holds the workflow it was
    /// admitted with, and a user who renamed that template in the meantime has not changed the
    /// instruction they authorized.
    func testIdempotentQueueRetryDoesNotReResolveAWorkflowThatIsGone() async {
        let store = AgentWorkflowStore.shared
        let wasHidden = store.isBuiltInHidden(.deepPlan)
        store.setBuiltInVisibility(.deepPlan, isVisible: true)
        defer { store.setBuiltInVisibility(.deepPlan, isVisible: !wasHidden) }

        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        let reference = AgentWorkflowReference.name(AgentWorkflow.deepPlan.displayName)
        let queued = await queueSend(fixture, workflowReference: reference)
        XCTAssertEqual(queued, .queued(replaced: false, duplicate: false))
        let admitted = await pendingSend(fixture)
        XCTAssertEqual(
            admitted?.pending?.workflow,
            AgentWorkflow.deepPlan.definition,
            "Admission resolves the workflow once and freezes it"
        )

        store.setBuiltInVisibility(.deepPlan, isVisible: false)
        XCTAssertNil(reference.resolved(), "precondition: the workflow no longer resolves")

        let retry = await queueSend(fixture, workflowReference: reference)
        XCTAssertEqual(retry, .queued(replaced: false, duplicate: true))
        let afterRetry = await pendingSend(fixture)
        XCTAssertEqual(afterRetry?.pending?.workflow, AgentWorkflow.deepPlan.definition)
    }

    /// A replacement is validated in full before it is installed, so a bad one is a no-op rather than
    /// a way to silently drop the message the user already queued.
    func testFailedReplacementLeavesTheOriginalEntryUntouched() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, message: "first", key: "key-1")

        let outcome = await queueSend(
            fixture,
            message: "second",
            key: "key-2",
            workflowReference: .id("missing-workflow"),
            replacePending: true
        )

        XCTAssertEqual(outcome, .send(.workflowUnavailable(reference: "missing-workflow")))
        let projection = await pendingSend(fixture)
        let pending = try XCTUnwrap(projection?.pending)
        XCTAssertEqual(pending.idempotencyKey, "key-1")
        XCTAssertEqual(pending.messagePreview, "first")
    }

    func testCancelMatchesTheCurrentEntryByKey() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)

        let resolvedEmptyTarget = await authorizedSendTarget(fixture)
        let emptyTarget = try XCTUnwrap(resolvedEmptyTarget)
        let notPending = await fixture.bridge.cancelPendingSend(
            target: emptyTarget,
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(notPending, .result(.notPending))

        _ = await queueSend(fixture, key: "key-1")
        let resolvedStaleTarget = await authorizedSendTarget(fixture)
        let staleTarget = try XCTUnwrap(resolvedStaleTarget)
        let mismatch = await fixture.bridge.cancelPendingSend(
            target: staleTarget,
            idempotencyKey: "key-0"
        )
        XCTAssertEqual(
            mismatch,
            .result(.pendingSendMismatch),
            "A stale cancel must not remove a message it does not name"
        )
        let survived = await pendingSend(fixture)
        XCTAssertNotNil(survived?.pending)

        let resolvedCancelTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedCancelTarget)
        let cancelled = await fixture.bridge.cancelPendingSend(
            target: target,
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(cancelled, .result(.cancelled))
        let afterCancel = await pendingSend(fixture)
        XCTAssertNil(afterCancel?.pending)
        XCTAssertTrue(fixture.host.sendRequests.count <= 1, "Cancelling delivers nothing")
    }

    /// Cancelling is a queue mutation under the same grant, so it needs the exact granted incarnation
    /// and the exact key — and nothing about the caller's own turn.
    ///
    /// A drifted or duplicate observer incarnation is still refused; that fence is what stops another
    /// live copy of the same session UUID from discarding a queue it never held the lease for.
    func testCancelIsGrantAuthorizedButStillRequiresTheExactObserverIncarnation() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, key: "key-1")

        let resolvedCancelTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedCancelTarget)

        // Cancelling under the grant succeeds with no condition on the caller's own turn, and it is
        // still purely a queue mutation: the cancel itself reaches no target transaction. (Admission
        // already made one refused drain attempt against the busy target; the cancel adds none.)
        let attemptsBeforeCancel = fixture.host.sendRequests.count
        let cancelled = await fixture.bridge.cancelPendingSend(target: target, idempotencyKey: "key-1")
        XCTAssertEqual(cancelled, .result(.cancelled))
        let afterCancel = await pendingSend(fixture)
        XCTAssertNil(afterCancel?.pending)
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            attemptsBeforeCancel,
            "A cancel must deliver nothing"
        )

        // A drifted observer incarnation is still refused: the exact granted identity remains the
        // fence, and it invalidates the grant rather than mutating a queue it never held.
        _ = await queueSend(fixture, key: "key-2")
        let resolvedAgainTarget = await authorizedSendTarget(fixture)
        let resolvedAgain = try XCTUnwrap(resolvedAgainTarget)
        fixture.host.candidates = [fixture.target]
        let refused = await fixture.bridge.cancelPendingSend(
            target: resolvedAgain,
            idempotencyKey: "key-2"
        )
        XCTAssertEqual(refused, .send(.rejected(.denied)))
    }

    /// Before the cutoff, a cancel wins outright: the delivery unwinds with no transcript mutation at
    /// all, exactly as a manual revocation in the same window does.
    func testCancelBeforeTheCommitCutoffStopsTheDeliveryEntirely() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageReadyTarget(fixture)
        fixture.host.beforeSendCommit = { [weak self] in
            guard let self, let target = await authorizedSendTarget(fixture) else { return }
            _ = await fixture.bridge.cancelPendingSend(target: target, idempotencyKey: "key-1")
        }

        let outcome = await queueSend(fixture, key: "key-1")

        XCTAssertEqual(fixture.host.sendCommitOutcomes, [.linkRevoked])
        XCTAssertEqual(
            outcome,
            .send(.rejected(.denied)),
            "The entry the caller asked about no longer exists"
        )
        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending)
        let snapshot = await fixture.authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0)
        XCTAssertEqual(
            snapshot.retainedSendOutcomeCount,
            0,
            "A delivery stopped before the fence must retain no receipt"
        )
    }

    /// After the cutoff, a cancel is answered truthfully rather than optimistically, and the delivery
    /// settles on its own terms.
    func testCancelAfterTheCommitCutoffReportsTooLateAndTheDeliverySettles() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageReadyTarget(fixture)
        let cancelOutcome = QueueOutcomeBox()
        fixture.host.afterSendCommit = { [weak self] in
            guard let self, let target = await authorizedSendTarget(fixture) else { return }
            cancelOutcome.value = await fixture.bridge.cancelPendingSend(
                target: target,
                idempotencyKey: "key-1"
            )
        }

        let outcome = await queueSend(fixture, key: "key-1")

        XCTAssertEqual(fixture.host.sendCommitOutcomes, [.committed])
        XCTAssertEqual(cancelOutcome.value, .result(.tooLate))
        guard case .send(.receipt) = outcome else {
            return XCTFail("The committed delivery must still settle, got \(String(describing: outcome))")
        }
        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending)
        guard case .delivered = try XCTUnwrap(projection?.lastResult?.outcome) else {
            return XCTFail("Settlement owns the result once the cutoff is crossed")
        }
    }

    /// A queued message belongs to the exact grant that admitted it. Stopping oversight ends it, and
    /// re-adding the same pair starts empty rather than inheriting authority the user removed.
    func testUnlinkDiscardsTheEntryAndReAddingTheSamePairStartsEmpty() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, key: "key-1")
        let queued = await pendingSend(fixture)
        XCTAssertNotNil(queued?.pending)

        let resolvedReference = await linkReference(fixture)
        let reference = try XCTUnwrap(resolvedReference)
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        _ = await addLink(fixture)

        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending, "A re-added pair must not inherit a queued message")
        XCTAssertNil(projection?.lastResult, "Nor the outcome the previous generation retained")
        stageReadyTarget(fixture)
        await publishTargetActivity(fixture, status: .idle, activity: 2000)
        await settleDrains { fixture.host.sendRequests.count > 1 }
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "Nothing may be delivered against the new generation"
        )
    }

    /// Queued sends are pre-authorization for a delivery the user is not present for, so quitting
    /// ends them rather than carrying them across a relaunch.
    func testTerminationFreezeDiscardsQueuedSends() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, key: "key-1")
        let queued = await pendingSend(fixture)
        XCTAssertNotNil(queued?.pending)
        let resolvedCancelTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedCancelTarget)

        fixture.bridge.freezeForTermination()

        let afterFreeze = await pendingSend(fixture)
        XCTAssertNil(afterFreeze?.pending)
        let refused = await fixture.bridge.queueSend(
            target: target,
            message: "ship it",
            idempotencyKey: "key-2",
            workflowReference: nil,
            replacePending: false
        )
        XCTAssertEqual(refused, .send(.rejected(.shuttingDown)))
    }

    /// A rejection the drain can never resolve ends the entry with a retained, non-retryable outcome
    /// rather than parking it forever against something that can only be re-rejected.
    func testAKeyTakenByAConflictingImmediateSendEndsTheQueuedEntryTruthfully() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, message: "queued text", key: "key-1")

        // An immediate send spends the same key on different text, so the ledger permanently holds a
        // receipt whose payload identity the queued entry can never match.
        stageReadyTarget(fixture)
        let resolvedImmediateTarget = await authorizedSendTarget(fixture)
        let immediate = try XCTUnwrap(resolvedImmediateTarget)
        guard case .receipt = await fixture.bridge.send(
            target: immediate,
            message: "different text",
            idempotencyKey: "key-1"
        ) else { return XCTFail("precondition: the immediate send must deliver") }

        await publishTargetActivity(fixture, status: .idle, activity: 2000)
        await settleDrains { await self.pendingSend(fixture)?.pending == nil }

        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending)
        XCTAssertEqual(projection?.lastResult?.outcome, .rejected(.idempotencyConflict))
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            2,
            "The queued text must never be delivered under a key that means something else"
        )
    }

    /// Settlement — not readiness — is what releases an entry parked behind an in-flight send.
    ///
    /// Nothing about the *target* changes while another send under the same key settles, so no
    /// readiness publication is coming to retrigger this drain. Without the ledger's own settlement
    /// trigger the entry would wait forever behind a send that already finished.
    func testAnEntryParkedBehindAnInFlightSendUnderItsKeyDrainsWhenThatSendSettles() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        _ = await queueSend(fixture, message: "review the diff", key: "key-1")
        let admittedParkReason = await pendingSend(fixture)?.pending?.parkReason
        XCTAssertEqual(
            admittedParkReason,
            .targetReadiness,
            "precondition: a busy target parks the entry on the readiness event"
        )

        // An immediate retry of the very same delivery holds the ledger key the queued entry drains
        // under. From inside that reservation window the key is genuinely in flight, so the drain
        // this readiness publication schedules must park on the send rather than fail the entry.
        stageReadyTarget(fixture)
        fixture.host.beforeSendCommit = { [weak self] in
            guard let self else { return }
            await publishTargetActivity(fixture, status: .idle, activity: 2000)
            await settleDrains {
                await self.pendingSend(fixture)?.pending?.parkReason == .sendInProgress
            }
        }

        let resolvedTarget = await authorizedSendTarget(fixture)
        let immediate = try XCTUnwrap(resolvedTarget)
        guard case let .receipt(receipt) = await fixture.bridge.send(
            target: immediate,
            message: "review the diff",
            idempotencyKey: "key-1"
        ) else { return XCTFail("precondition: the immediate send must deliver") }
        XCTAssertFalse(receipt.duplicate)

        await settleDrains { await self.pendingSend(fixture)?.pending == nil }

        let projection = await pendingSend(fixture)
        XCTAssertNil(
            projection?.pending,
            "The settlement trigger must release an entry no readiness event would have retried"
        )
        XCTAssertEqual(projection?.lastResult?.idempotencyKey, "key-1")
        guard case let .delivered(settled) = try XCTUnwrap(projection?.lastResult?.outcome) else {
            return XCTFail("Expected the parked entry to settle on the delivery that overtook it")
        }
        XCTAssertTrue(settled.duplicate, "The queued text already landed under this key")
        XCTAssertEqual(settled.targetItemID, receipt.targetItemID)
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            2,
            "The parked entry must not reach the target transaction a second time"
        )
    }

    // MARK: Mid-drain trigger fence

    /// Mutable capture for the entry state a hook observes from inside the drain.
    private final class MissedTriggerBox {
        var value: Set<AgentSessionLinkPendingSend.ParkReason>?
    }

    /// The readiness edge a drain races is the only one its park will ever wait for.
    ///
    /// A drain reads the target once, at its start, and decides how to park several awaits later. A
    /// publication that lands inside that window finds an entry that is not `.pending`, so it has
    /// nothing to schedule — and with no timer and no polling behind the queue, dropping it strands
    /// the message for good.
    func testAReadinessEdgeThatLandsMidDrainIsNotLostByThePark() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        fixture.host.beforeSendCommit = { [weak self] in
            guard let self else { return }
            // The re-drain the fence owes must find a target that now accepts the message.
            fixture.host.beforeSendCommit = { [weak self] in self?.stageReadyTarget(fixture) }
            // The target reports it is ready while this drain is already `.draining`.
            await publishTargetActivity(fixture, status: .idle, activity: 2000)
        }

        let queued = await queueSend(fixture, message: "review the diff", key: "key-1")

        XCTAssertEqual(
            queued,
            .queued(replaced: false, duplicate: false),
            "precondition: the drain that raced the edge still parked the entry"
        )
        await settleDrains { await self.pendingSend(fixture)?.pending == nil }

        let projection = await pendingSend(fixture)
        XCTAssertNil(projection?.pending, "the edge that landed mid-drain must still be consumed")
        guard case .delivered = try XCTUnwrap(projection?.lastResult?.outcome) else {
            return XCTFail("Expected the re-drain to deliver the queued message")
        }
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            2,
            "exactly one re-drain, caused by the edge the first drain raced — not a retry loop"
        )
        XCTAssertEqual(fixture.host.sendRequests.last?.request.message, "review the diff")
    }

    /// A settlement that lands mid-drain is captured on the same fence, and releases only a park it
    /// actually frees.
    ///
    /// Both halves matter. The capture is what stops an entry parked on the ledger from waiting for a
    /// slot that was freed while it was suspended; the reason match is what stops a drain's own
    /// settlement from re-driving every other draining entry, which would be a livelock rather than a
    /// fence. This also covers the reservation the workflow-unavailable path releases: it stages no
    /// target work at all, so the trigger it fires is the only evidence it settled the ledger.
    func testASettlementEdgeThatLandsMidDrainIsRecordedAndReleasesOnlyAMatchingPark() async {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        stageBusyTarget(fixture)
        let recorded = MissedTriggerBox()
        fixture.host.beforeSendCommit = { [weak self] in
            guard let self else { return }
            fixture.host.beforeSendCommit = nil
            guard let target = await authorizedSendTarget(fixture) else { return }
            // A second key reserves and releases a ledger slot on this link while the queued entry is
            // `.draining`, without ever reaching the target transaction.
            let unavailable = await fixture.bridge.send(
                target: target,
                message: "unrelated",
                idempotencyKey: "key-2",
                workflowReference: .id("missing-workflow")
            )
            XCTAssertEqual(unavailable, .workflowUnavailable(reference: "missing-workflow"))
            recorded.value = await pendingSend(fixture)?.pending?.missedDrainTriggers
        }

        let queued = await queueSend(fixture, message: "review the diff", key: "key-1")

        XCTAssertEqual(queued, .queued(replaced: false, duplicate: false))
        XCTAssertEqual(
            recorded.value,
            [.sendInProgress, .ledgerSaturated],
            "a reservation released on this link must be recorded, not dropped, on a draining entry"
        )
        let projection = await pendingSend(fixture)
        XCTAssertEqual(projection?.pending?.parkReason, .targetReadiness)
        XCTAssertEqual(
            projection?.pending?.missedDrainTriggers,
            [],
            "the record is spent by the park it raced, whether or not it released it"
        )
        await settleDrains { fixture.host.sendRequests.count > 1 }
        XCTAssertEqual(
            fixture.host.sendRequests.count,
            1,
            "a settlement must not re-drive an entry that is waiting on target readiness"
        )
    }

    /// The fence's own rule, including the ledger interleavings the transaction stack cannot stage:
    /// a park only re-drives itself when the exact edge it is waiting for already passed.
    func testMidDrainTriggerRecordReleasesOnlyTheParkItMatchesAndIsSpentEitherWay() {
        var entry = slotEntry(key: "a", digest: "d1", phase: .pending)
        let otherLink = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)

        func note(settledOn settled: DomainAgentSessionLinkReference) {
            entry.beginDrainWindow()
            XCTAssertEqual(entry.phase, .draining)
            entry.noteMissedDrainTriggers(AgentSessionLinkPendingSend.parkReasonsReleased(
                bySendSettlementOn: settled,
                forEntryOn: entry.reference
            ))
        }

        // Same-link settlement: releases this link's in-flight-send park and the authority-wide one.
        note(settledOn: entry.reference)
        XCTAssertTrue(entry.park(reason: .ledgerSaturated))
        XCTAssertEqual(entry.phase, .pending)
        XCTAssertEqual(entry.parkReason, .ledgerSaturated)
        XCTAssertTrue(entry.missedDrainTriggers.isEmpty, "the record is consumed by the park that used it")
        note(settledOn: entry.reference)
        XCTAssertTrue(entry.park(reason: .sendInProgress))

        // The same edge against a park it does not free: the readiness publication this entry now
        // waits for has not happened yet and will be delivered normally.
        note(settledOn: entry.reference)
        XCTAssertFalse(entry.park(reason: .targetReadiness))
        XCTAssertTrue(entry.missedDrainTriggers.isEmpty, "a record that releases nothing is still spent")

        // Another link's settlement frees an authority-wide slot but not this link's in-flight send.
        note(settledOn: otherLink)
        XCTAssertFalse(entry.park(reason: .sendInProgress))
        note(settledOn: otherLink)
        XCTAssertTrue(entry.park(reason: .ledgerSaturated))

        // Readiness is the one trigger that is not park-reason specific: proof the target moved is
        // worth re-evaluating whatever the entry parked on.
        for reason in [
            AgentSessionLinkPendingSend.ParkReason.targetReadiness,
            .sendInProgress,
            .ledgerSaturated
        ] {
            entry.beginDrainWindow()
            entry.noteMissedDrainTriggers(
                AgentSessionLinkPendingSend.parkReasonsReleasedByTargetReadiness
            )
            XCTAssertTrue(entry.park(reason: reason))
        }
    }

    // MARK: Slot arbitration

    private func slotEntry(key: String, digest: String, phase: AgentSessionLinkPendingSend.Phase) -> AgentSessionLinkPendingSend {
        AgentSessionLinkPendingSend(
            revision: UUID(),
            reference: DomainAgentSessionLinkReference(linkID: UUID(), generation: 1),
            observerEndpoint: makeCandidate(windowID: 1).domainEndpoint,
            targetSessionID: UUID(),
            message: "queued",
            idempotencyKey: key,
            requestDigest: digest,
            workflow: nil,
            queuedAt: Date(timeIntervalSince1970: 1000),
            phase: phase
        )
    }

    /// The arbitration runs twice per admission — once before anything is resolved and again after
    /// those awaits — so it has to be one rule rather than two approximations of one.
    func testSlotArbitrationCoversEveryAdmissionCase() {
        XCTAssertEqual(
            AgentSessionLinkPendingSend.slotDecision(
                current: nil,
                idempotencyKey: "a",
                requestDigest: "d1",
                replacePending: false
            ),
            .install(replaced: false)
        )
        let entry = slotEntry(key: "a", digest: "d1", phase: .pending)
        XCTAssertEqual(
            AgentSessionLinkPendingSend.slotDecision(
                current: entry,
                idempotencyKey: "a",
                requestDigest: "d1",
                replacePending: false
            ),
            .replay(revision: entry.revision)
        )
        XCTAssertEqual(
            AgentSessionLinkPendingSend.slotDecision(
                current: entry,
                idempotencyKey: "a",
                requestDigest: "d2",
                replacePending: true
            ),
            .conflict,
            "replace_pending must not turn a same-key payload change into a replacement"
        )
        XCTAssertEqual(
            AgentSessionLinkPendingSend.slotDecision(
                current: entry,
                idempotencyKey: "b",
                requestDigest: "d2",
                replacePending: false
            ),
            .occupied
        )
        XCTAssertEqual(
            AgentSessionLinkPendingSend.slotDecision(
                current: entry,
                idempotencyKey: "b",
                requestDigest: "d2",
                replacePending: true
            ),
            .install(replaced: true)
        )
        for phase in [AgentSessionLinkPendingSend.Phase.committing, .committed] {
            XCTAssertEqual(
                AgentSessionLinkPendingSend.slotDecision(
                    current: slotEntry(key: "a", digest: "d1", phase: phase),
                    idempotencyKey: "b",
                    requestDigest: "d2",
                    replacePending: true
                ),
                .tooLate,
                "An entry past its cutoff cannot be displaced"
            )
        }
    }

    func testSendFromADriftedObserverIsDeniedWithoutReachingTheTarget() async throws {
        let fixture = makeFixture()
        _ = await addLink(fixture)
        let resolvedTarget = await authorizedSendTarget(fixture)
        let target = try XCTUnwrap(resolvedTarget)
        // The observer's incarnation changes after the lease was issued.
        fixture.host.candidates = [fixture.target]

        let driftedOutcome = await fixture.bridge.send(
            target: target,
            message: "hi",
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(driftedOutcome, .rejected(.denied))
        XCTAssertTrue(fixture.host.sendRequests.isEmpty)
    }

    // MARK: - Two-window add/revoke/status integration

    /// Publishes one target status and settles the projection pass it triggers.
    private func publishStatus(
        _ fixture: Fixture,
        _ status: DomainAgentSessionLinkStatus,
        pendingInteraction: DomainAgentSessionLinkPendingInteractionKind? = nil,
        preview: String? = nil,
        at seconds: TimeInterval
    ) async {
        fixture.host.snapshotOverrides[fixture.target.sessionID] = DomainAgentSessionObservationSnapshot(
            sessionID: fixture.target.sessionID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: status,
            idleForSend: status == .idle && pendingInteraction == nil,
            pendingInteractionKind: pendingInteraction,
            latestVisibleAssistantPreview: preview,
            visibleRowCount: Int(seconds),
            lastActivityAt: Date(timeIntervalSince1970: seconds)
        )
        fixture.host.fireObservation(for: fixture.target.sessionID)
        await fixture.bridge.test_settleProjections()
    }

    /// The whole point of the feature: one add in window 1 must leave window 2's Oversee rows, the
    /// observer's agent-facing inventory, and the authority's grant describing the same membership.
    ///
    /// `testAddPublishesProjectionsAtBothEndpoints` already covers the UI rows. This adds the
    /// agent-facing half: nothing else proves the bridge publishes the prompt inventory the
    /// supplement renders from, so a regression there would silently stop teaching the observer
    /// about a monitor the UI still shows.
    func testTwoWindowAddPublishesUIRowsAndPromptInventoryFromOneMembershipRevision() async throws {
        let fixture = makeFixture()
        guard case let .added(linkID, _) = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()

        let observerProps = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID])
        let targetProps = try XCTUnwrap(fixture.host.publishedProps[fixture.target.sessionID])
        XCTAssertEqual(observerProps.outbound.map(\.linkID), [linkID])
        XCTAssertEqual(targetProps.inbound.map(\.linkID), [linkID])

        let inventory = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])
        XCTAssertEqual(inventory.observerSessionID, fixture.observer.sessionID)
        XCTAssertEqual(inventory.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertGreaterThan(inventory.linkSetRevision, 0)
        XCTAssertFalse(inventory.isEmpty)

        // Being observed grants the target nothing, so its own outbound inventory stays empty at the
        // never-acknowledged revision and can never owe it a supplement.
        let targetInventory = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.target.sessionID])
        XCTAssertTrue(targetInventory.isEmpty)
        XCTAssertEqual(targetInventory.linkSetRevision, 0)
    }

    /// Either endpoint may stop the link. The target's Stop button revokes with the `linkID` and
    /// `generation` carried on its **inbound** row, so this drives revocation from exactly that data
    /// rather than from the observer's outbound row.
    func testTargetInitiatedStopFromItsInboundRowClearsBothEndpoints() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()

        let targetProps = try XCTUnwrap(fixture.host.publishedProps[fixture.target.sessionID])
        let inboundRow = try XCTUnwrap(targetProps.inbound.first)
        await fixture.bridge.revokeLink(linkID: inboundRow.linkID, generation: inboundRow.generation)
        await fixture.bridge.test_settleProjections()

        let clearedObserver = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID])
        let clearedTarget = try XCTUnwrap(fixture.host.publishedProps[fixture.target.sessionID])
        XCTAssertTrue(clearedObserver.outbound.isEmpty)
        XCTAssertTrue(clearedTarget.inbound.isEmpty)
        XCTAssertEqual(
            clearedObserver.recentNotices.first?.message,
            "Oversight of Build API ended: the relationship was unlinked."
        )
        XCTAssertEqual(
            clearedTarget.recentNotices.first?.message,
            "Planning no longer oversees this session: the relationship was unlinked."
        )
        let stateAfterRevoke = await pollState(fixture)
        XCTAssertNil(stateAfterRevoke)
    }

    /// A revoked last link must publish an empty inventory at a *new* revision: that revision change
    /// is the only signal that owes the observer its single closing supplement.
    func testRevokingTheLastLinkPublishesAnEmptyInventoryAtANewRevision() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()
        let active = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])

        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        await fixture.bridge.test_settleProjections()

        let ended = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])
        XCTAssertTrue(ended.isEmpty)
        XCTAssertGreaterThan(ended.linkSetRevision, active.linkSetRevision)
    }

    /// Re-adding oversight after the last link was revoked must never leave a published inventory
    /// that says "empty" while the replacement grant is already live and callable.
    ///
    /// Pins the R7-A sequence: an inventory the observer already accepted, a final revocation that
    /// publishes empty, then a replacement activation. `activateLink` commits the grant inside the
    /// authority actor while `addMonitorLink` is suspended on the hop, so between that instant and
    /// the projection refresh the observer is genuinely linked. A dispatch composing its supplement
    /// there against the still-empty published inventory renders the *terminal* revocation notice —
    /// "you are no longer overseeing any session", "the tool is no longer available to you" — both
    /// already false, since `hasActiveOutboundLink` answers `true` and the tool is advertised again.
    ///
    /// The observation install is the assertion point because the bridge performs it after
    /// activation and before the refresh, i.e. strictly inside that window. What must hold there is
    /// that the published inventory is never a claimable *lie*: it is either withheld outright, or it
    /// already names the new target. Never empty-while-linked.
    func testReAddingAfterTheLastRevocationNeverPublishesAnEmptyInventoryWhileLinked() async throws {
        let fixture = makeFixture()
        let observerEndpoint = fixture.observer.domainEndpoint
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()

        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        await fixture.bridge.test_settleProjections()
        let revoked = try XCTUnwrap(fixture.host.publishedInventoriesByEndpoint[observerEndpoint])
        XCTAssertTrue(revoked.isEmpty, "precondition: the closing inventory is published empty")

        var enteredWindow = false
        var publishedInWindow: AgentSessionLinkPromptInventory?
        fixture.host.duringObservationInstall = { host in
            enteredWindow = true
            publishedInWindow = host.publishedInventoriesByEndpoint[observerEndpoint]
        }
        guard case .added = await addLink(fixture) else { return XCTFail("re-add failed") }

        // Guards the assertion below against passing because the window was never reached.
        XCTAssertTrue(enteredWindow, "the post-activation window was never entered")
        if let publishedInWindow {
            XCTAssertEqual(
                publishedInWindow.items.map(\.targetSessionID),
                [fixture.target.sessionID],
                "an inventory published while the grant is live must name it"
            )
        }
        let settled = try XCTUnwrap(fixture.host.publishedInventoriesByEndpoint[observerEndpoint])
        XCTAssertEqual(settled.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertGreaterThan(settled.linkSetRevision, revoked.linkSetRevision)
    }

    /// Status churn on the target must never advance the observer's link-set revision: if it did,
    /// every streamed chunk on a busy target would re-inject an oversight supplement.
    func testTargetStatusTransitionsNeverAdvanceTheObserverLinkSetRevision() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()
        let seeded = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])

        await publishStatus(fixture, .running, preview: "working", at: 200)
        await publishStatus(fixture, .awaitingUser, pendingInteraction: .approval, at: 300)
        await publishStatus(fixture, .idle, preview: "done", at: 400)

        let after = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])
        XCTAssertEqual(after.linkSetRevision, seeded.linkSetRevision)
        XCTAssertEqual(after.items.map(\.targetSessionID), [fixture.target.sessionID])
    }

    /// The observer's poll snapshot and Oversee row must follow the full user-visible arc, and each
    /// distinct state must advance `change_sequence` so a parked `wait` wakes on every one of them.
    func testObserverFollowsRunningThenAwaitingUserThenIdleAndWakesOnEachTransition() async throws {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        await fixture.bridge.test_settleProjections()
        let rawSeeded = await pollState(fixture)
        let seededState = try XCTUnwrap(rawSeeded)
        XCTAssertEqual(seededState.snapshot.status, .idle)

        await publishStatus(fixture, .running, preview: "working", at: 200)
        let rawRunning = await pollState(fixture)
        let running = try XCTUnwrap(rawRunning)
        XCTAssertEqual(running.snapshot.status, .running)
        XCTAssertFalse(running.snapshot.idleForSend)
        XCTAssertGreaterThan(running.changeSequence, seededState.changeSequence)
        let runningRow = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID]?.outbound.first)
        XCTAssertEqual(runningRow.status, .running)

        await publishStatus(fixture, .awaitingUser, pendingInteraction: .approval, at: 300)
        let rawAwaiting = await pollState(fixture)
        let awaiting = try XCTUnwrap(rawAwaiting)
        XCTAssertEqual(awaiting.snapshot.status, .awaitingUser)
        XCTAssertEqual(awaiting.snapshot.pendingInteractionKind, .approval)
        XCTAssertFalse(awaiting.snapshot.idleForSend)
        XCTAssertGreaterThan(awaiting.changeSequence, running.changeSequence)
        let awaitingRow = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID]?.outbound.first)
        XCTAssertEqual(awaitingRow.status, .awaitingUser)

        await publishStatus(fixture, .idle, preview: "done", at: 400)
        let rawIdle = await pollState(fixture)
        let idle = try XCTUnwrap(rawIdle)
        XCTAssertEqual(idle.snapshot.status, .idle)
        XCTAssertNil(idle.snapshot.pendingInteractionKind)
        XCTAssertTrue(idle.snapshot.idleForSend)
        XCTAssertGreaterThan(idle.changeSequence, awaiting.changeSequence)
        let idleRow = try XCTUnwrap(fixture.host.publishedProps[fixture.observer.sessionID]?.outbound.first)
        XCTAssertEqual(idleRow.status, .idle)
    }

    // MARK: - Cross-window tool advertisement isolation

    /// Advertisement notifications one membership change produces.
    ///
    /// Two, on purpose: the add/revoke path notifies inline, and the change feed notifies again when
    /// it delivers the matching authority event. The inline call is what keeps the notification alive
    /// when the feed's bounded buffer drops an event; the feed call is what still covers transitions
    /// the bridge did not initiate itself, such as the stale-endpoint sweep. Both are idempotent
    /// `tools/list` notifications, so the cost of the overlap is one redundant refresh and the cost of
    /// dropping either is an observer stuck advertising the wrong catalog.
    private static let invalidationsPerMembershipChange = 2

    /// Waits for at least `count` advertisement invalidations, then returns everything recorded.
    private func awaitInvalidations(
        _ fixture: Fixture,
        count: Int,
        _ description: String
    ) async throws -> [UUID] {
        try await AsyncTestWait.waitUntil(description) {
            await fixture.advertisement.count() >= count
        }
        return await fixture.advertisement.drain()
    }

    /// Drains every invalidation recorded so far, fencing against **both** notification sources.
    ///
    /// The inline and feed notifications are not ordered against each other, so counting alone cannot
    /// prove nothing earlier is still in flight — the count can be reached by two notifications for a
    /// late change while an earlier feed event is still queued. Adding a link for an unrelated
    /// observer and waiting for *its* feed notification restores the proof: the feed is a serial
    /// `for await` loop, so its notification for the fence event cannot arrive before its notification
    /// for anything enqueued ahead of it.
    ///
    /// Returns everything recorded up to the fence, with the fence's own notifications removed.
    private func drainInvalidationsBehindFence(_ fixture: Fixture) async throws -> [UUID] {
        let fence = makeCandidate(windowID: 97, displayName: "Fence")
        fixture.host.candidates.append(fence)
        guard case .added = await fixture.bridge.addMonitorLink(
            observerSessionID: fence.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        ) else {
            XCTFail("fence link add failed")
            return []
        }
        try await AsyncTestWait.waitUntil("both fence invalidations") {
            await fixture.advertisement.count(of: fence.sessionID)
                >= Self.invalidationsPerMembershipChange
        }
        return await fixture.advertisement.drain().filter { $0 != fence.sessionID }
    }

    /// The first inbound link advertises the self-scoped waiting declaration to the target; the last
    /// revocation removes it. Both endpoints therefore refresh exactly at those membership edges.
    func testAddAndRevokeInvalidateObserverAndTargetsToolAdvertisement() async throws {
        let fixture = makeFixture()
        fixture.bridge.test_startChangeFeed()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }

        let afterAdd = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange * 2,
            "both add invalidations"
        )
        XCTAssertEqual(Set(afterAdd), [fixture.observer.sessionID, fixture.target.sessionID])

        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)

        let afterRevoke = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange * 2,
            "both revoke invalidations"
        )
        XCTAssertEqual(Set(afterRevoke), [fixture.observer.sessionID, fixture.target.sessionID])
    }

    /// The inline notification is the half that survives a dropped change-feed event, so it has to
    /// land without the feed running at all.
    func testMembershipChangesInvalidateAdvertisementWithoutTheChangeFeed() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        let afterAdd = await fixture.advertisement.drain()
        XCTAssertEqual(
            Set(afterAdd),
            [fixture.observer.sessionID, fixture.target.sessionID],
            "an add with no feed running must re-advertise both endpoints"
        )

        guard let reference = await linkReference(fixture) else { return XCTFail("missing link") }
        await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        let afterRevoke = await fixture.advertisement.drain()
        XCTAssertEqual(
            Set(afterRevoke),
            [fixture.observer.sessionID, fixture.target.sessionID],
            "a last revoke with no feed running must re-advertise both endpoints"
        )
    }

    /// The stale-endpoint sweep is a self-repair path, so it must not be the one membership mutation
    /// that still depends on the lossy feed to re-advertise. Runs with the feed stopped, so the
    /// inline notification is the whole assertion.
    func testStaleEndpointSweepReAdvertisesWithoutTheChangeFeed() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        _ = await fixture.advertisement.drain()

        // No lifecycle hook fires: the observer's window simply stops reporting the endpoint.
        fixture.host.candidates = [fixture.target]
        await fixture.bridge.revalidateLiveEndpoints()

        let recorded = await fixture.advertisement.drain()
        XCTAssertEqual(
            Set(recorded),
            [fixture.observer.sessionID, fixture.target.sessionID],
            "the sweep revoked the grant without telling both affected endpoints to re-advertise"
        )
    }

    /// Adding a link to a target that rebound in place makes the authority revoke the previous
    /// incarnation's inbound links from inside `reserveLink`. Those belong to a *different* observer,
    /// which loses its grant and must be re-advertised on the same call rather than through the feed.
    func testReAddingAReboundTargetReAdvertisesTheDispossessedObserver() async {
        let fixture = makeFixture()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        _ = await fixture.advertisement.drain()

        let rebound = makeCandidate(
            windowID: fixture.target.windowID,
            sessionID: fixture.target.sessionID,
            workspaceID: fixture.target.workspaceID,
            tabID: fixture.target.tabID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: fixture.target.bindingTransitionGeneration &+ 1,
            displayName: "Build API"
        )
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, secondObserver, rebound]

        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("expected added, got \(second)") }

        let recorded = await fixture.advertisement.drain()
        XCTAssertEqual(
            Set(recorded),
            [fixture.observer.sessionID, secondObserver.sessionID, fixture.target.sessionID],
            "the rebound did not re-advertise every endpoint whose tool availability changed"
        )
        let activeLinks = await fixture.authority.snapshot().activeLinkCount
        XCTAssertEqual(activeLinks, 1, "only the new observer's link survives the drift")
        let survivor = await linkReference(fixture, observer: secondObserver.sessionID)
        XCTAssertNotNil(survivor)
    }

    /// A target running, asking for approval, and going idle changes nobody's grant, so it must
    /// produce no `list_changed` traffic at all.
    ///
    /// Proven by ordering: the three status events are enqueued ahead of the fence, so draining behind
    /// the fence would surface anything they emitted.
    func testTargetStatusChangeNeverInvalidatesAnyToolAdvertisement() async throws {
        let fixture = makeFixture()
        fixture.bridge.test_startChangeFeed()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        _ = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange,
            "both add invalidations"
        )

        await publishStatus(fixture, .running, preview: "working", at: 200)
        await publishStatus(fixture, .awaitingUser, pendingInteraction: .approval, at: 300)
        await publishStatus(fixture, .idle, preview: "done", at: 400)

        let recorded = try await drainInvalidationsBehindFence(fixture)
        XCTAssertEqual(
            recorded,
            [],
            "status churn re-advertised a catalog; a status change grants nothing"
        )
    }

    /// Two observers of one target are independent grants. Adding the second must re-advertise only
    /// the second observer, leaving the first observer's connection untouched.
    func testASecondObserverInvalidatesOnlyItsOwnAdvertisement() async throws {
        let fixture = makeFixture()
        let secondObserver = makeCandidate(windowID: 3, displayName: "Docs")
        fixture.host.candidates = [fixture.observer, fixture.target, secondObserver]
        fixture.bridge.test_startChangeFeed()
        guard case .added = await addLink(fixture) else { return XCTFail("first add failed") }
        _ = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange,
            "both first-add invalidations"
        )

        let second = await fixture.bridge.addMonitorLink(
            observerSessionID: secondObserver.sessionID,
            rawTargetSessionID: fixture.target.sessionID.uuidString
        )
        guard case .added = second else { return XCTFail("second add failed") }

        let recorded = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange,
            "both second-add invalidations"
        )
        XCTAssertEqual(Set(recorded), [secondObserver.sessionID])

        // Each observer's inventory names the shared target without referencing the other observer.
        await fixture.bridge.test_settleProjections()
        let firstInventory = try XCTUnwrap(fixture.host.publishedPromptInventories[fixture.observer.sessionID])
        let secondInventory = try XCTUnwrap(fixture.host.publishedPromptInventories[secondObserver.sessionID])
        XCTAssertEqual(firstInventory.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertEqual(secondInventory.items.map(\.targetSessionID), [fixture.target.sessionID])
        XCTAssertEqual(secondInventory.observerSessionID, secondObserver.sessionID)
    }

    /// A duplicate add creates no second generation, so it changes no grant set and must not emit a
    /// redundant `list_changed` to the observer that already holds the link.
    func testDuplicateAddDoesNotReAdvertise() async throws {
        let fixture = makeFixture()
        fixture.bridge.test_startChangeFeed()
        guard case .added = await addLink(fixture) else { return XCTFail("add failed") }
        _ = try await awaitInvalidations(
            fixture,
            count: Self.invalidationsPerMembershipChange,
            "both add invalidations"
        )

        guard case .alreadyLinked = await addLink(fixture) else { return XCTFail("expected alreadyLinked") }

        let recorded = try await drainInvalidationsBehindFence(fixture)
        XCTAssertEqual(
            recorded,
            [],
            "the duplicate add re-advertised despite creating no new grant"
        )
    }
}

// MARK: - Helpers

private extension AgentSessionLinkRuntimeBridge {
    /// Sends with no per-message workflow.
    ///
    /// Every case above this line predates the override and exercises the plain path; the workflow
    /// cases call the full API. Deliberately a forwarding overload rather than a production default:
    /// a real caller that forgets to pass a workflow must not silently drop the user's one.
    func send(
        target: AuthorizedTarget,
        message: String,
        idempotencyKey: String
    ) async -> SendOutcome {
        await send(
            target: target,
            message: message,
            idempotencyKey: idempotencyKey,
            workflowReference: nil
        )
    }
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
