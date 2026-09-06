import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

private actor AutoWakeCatalogAuthorityGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Bool, Never>] = []

    func requirement() async -> Bool {
        if !entered {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if isOpen {
            return true
        }
        return await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }
}

/// Orchestration, identity, and provenance for the one automatic lane-update follow-up.
///
/// Deliberately driven through the same publication hook and claim seam the runtime bridge and every
/// provider family use, rather than by calling the coordinator's internals: what has to be true is
/// that a wake reserves exactly one turn, that the reservation is visible to other observers, and
/// that the acceptance boundary is the provider's own signal.
@MainActor
final class AgentSessionLinkAutoWakeTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Dispatch identity

    /// The wake ID survives a round trip through the opaque dispatch ID.
    ///
    /// This is what makes acceptance decidable from the claim alone: the provider hands back a claim,
    /// and the wake it settles is read out of that claim rather than out of whatever the session
    /// happens to hold at the time.
    func testAutoWakeDispatchIDRoundTripsItsWakeAndNothingElseClaimsToBeOne() {
        let wakeID = UUID()
        XCTAssertEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID).autoWakeID,
            wakeID
        )
        XCTAssertNotEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID),
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: UUID())
        )
        for ordinary: AgentSessionLinkPromptDispatchID in [
            .claudeNativeSend(wakeID),
            .codexNativeSend(wakeID),
            .codexFallback(queueID: wakeID),
            .headlessRun(runID: wakeID),
            .acpPromptTurn(runAttemptID: wakeID),
            .acpActiveSteering(runAttemptID: wakeID),
            .waitingContinuation(waitID: wakeID)
        ] {
            XCTAssertNil(
                ordinary.autoWakeID,
                "an ordinary provider dispatch must never be mistaken for a wake"
            )
        }
        XCTAssertNil(AgentSessionLinkPromptDispatchID(rawValue: "lane.autowake:nope").autoWakeID)

        // The historical two-component form named a fence that no longer exists. It must read as
        // *malformed reserved family*, never as an ordinary dispatch: the physical seam classifies by
        // family first precisely so a stale identity cannot slip through the ordinary pass-through.
        let legacy = AgentSessionLinkPromptDispatchID(rawValue: "lane.autowake:\(wakeID.uuidString):3")
        XCTAssertNil(legacy.autoWakeID)
        XCTAssertTrue(legacy.isAutoWakeFamily)
    }

    /// A wake's claim is refused outright unless the lane batch it exists to deliver is present.
    ///
    /// The requirement is a property of the dispatch identity, not a caller-supplied flag, so it
    /// cannot be forgotten by one provider family and honoured by another. An ordinary dispatch in
    /// the same state is still allowed to carry membership alone.
    func testAWakeClaimRequiresTheLaneBatchWhileAnOrdinaryDispatchDoesNot() {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)

        let store = AgentSessionLinkOutboundPromptClaimStore()
        let ordinary = store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: nil,
            render: AgentSessionLinkPrompts.rendered
        )
        XCTAssertNotNil(ordinary, "membership alone is a perfectly good ordinary dispatch")
        XCTAssertNil(ordinary?.passive)

        let wakeStore = AgentSessionLinkOutboundPromptClaimStore()
        XCTAssertNil(
            wakeStore.claim(
                dispatchID: .autoWake(wakeID: UUID()),
                epoch: epoch,
                inventory: inventory,
                passiveNotices: nil,
                render: AgentSessionLinkPrompts.rendered
            ),
            "a wake must not start a turn carrying membership alone"
        )
    }

    // MARK: - Guidance revision

    /// A provider context that physically accepted revision 4 is re-owed revision 5 in full. Merely
    /// rendering or abandoning revision 5 does not advance the acknowledgement; only physical
    /// acceptance earns the reminder, and a rebuilt context owes the full block again.
    func testRevisionFiveReOwesFullGuidanceAndReminderIsAcceptanceGated() throws {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)
        let store = AgentSessionLinkOutboundPromptClaimStore()

        let first = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 1),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(first.laneGuidanceMode, .full)

        // Seed the only state an upgrade has that a fresh context cannot produce: this exact epoch
        // physically accepted the prior guidance revision. The memberwise copy preserves all claim
        // authority; only the revision the provider is treated as having seen is historical.
        let passive = try XCTUnwrap(first.passive)
        let revisionFourClaim = AgentSessionLinkOutboundPromptClaim(
            observerSessionID: first.observerSessionID,
            dispatchID: first.dispatchID,
            epochToken: first.epochToken,
            membership: first.membership,
            passiveQueue: first.passiveQueue,
            passive: AgentSessionLinkOutboundPromptClaim.PassiveStatusComponent(
                observerEndpoint: passive.observerEndpoint,
                receipt: passive.receipt,
                includesUnattributedOverflow: passive.includesUnattributedOverflow,
                guidanceRevision: 4,
                displayAttribution: passive.displayAttribution
            ),
            laneGuidanceMode: first.laneGuidanceMode,
            fragment: first.fragment
        )
        store.accept(revisionFourClaim)
        XCTAssertEqual(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID),
            4
        )

        let reOwed = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 2),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(reOwed.laneGuidanceMode, .full)
        XCTAssertTrue(reOwed.fragment.contains("Guidance revision 5 supersedes"))
        XCTAssertTrue(reOwed.fragment.contains("attributed attention request"))
        XCTAssertTrue(reOwed.fragment.contains("master Auto-wake"))
        XCTAssertTrue(reOwed.fragment.contains("lane&apos;s own toggle"))
        XCTAssertTrue(reOwed.fragment.contains("exact lane&apos;s status Auto-wake snooze"))
        XCTAssertTrue(reOwed.fragment.contains("status and overflow"))
        XCTAssertTrue(reOwed.fragment.contains("selection and snooze"))
        XCTAssertTrue(reOwed.fragment.contains("without changing any of them"))
        XCTAssertTrue(reOwed.fragment.contains("Unlink, revocation, exact authority, readiness"))
        XCTAssertFalse(reOwed.fragment.contains("It cannot select a lane"))
        XCTAssertTrue(reOwed.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // Rendering is not acceptance: an abandoned batch leaves the wording still owed.
        store.abandon(reOwed)
        let retried = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 3),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(retried.laneGuidanceMode, .full)

        store.accept(retried)
        XCTAssertEqual(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID),
            AgentSessionLinkPrompts.currentLaneGuidanceRevision
        )

        let later = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 4),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(later.laneGuidanceMode, .reminder)
        XCTAssertTrue(later.fragment.contains("Lane update or attributed attention:"))
        XCTAssertTrue(later.fragment.contains("still-applicable standing instruction"))
        XCTAssertTrue(later.fragment.contains("attention supplies no task"))
        XCTAssertTrue(later.fragment.contains("Never invent work"))
        XCTAssertTrue(later.fragment.contains("another session&apos;s interaction"))
        XCTAssertTrue(later.fragment.contains("Surface ambiguity or surprises"))
        XCTAssertFalse(later.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // A rebuilt provider conversation never saw the wording, so it is owed in full again.
        store.invalidateAcknowledgedContext(observerSessionID: observerSessionID)
        XCTAssertNil(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID)
        )
        let rebuilt = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 5),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(rebuilt.laneGuidanceMode, .full)
    }

    // MARK: - Readiness

    /// A reserved wake makes the observer busy for every other observer's `send`.
    ///
    /// Without this the wake and an inbound delivery race for the same terminal boundary, and the
    /// loser is silently dropped.
    func testAReservedWakeMakesTheObserverUnsendable() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot), .ready)
        snapshot.pendingOversightAutoWake = true
        XCTAssertEqual(
            AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot).blockReason,
            .targetNotIdle
        )
    }

    // MARK: - Provenance

    /// The visible row is keyed by the wake, stamped at physical acceptance, and says nothing about
    /// which sessions changed.
    func testLaneUpdateSystemRowIsKeyedByWakeAndCarriesNoTargetDetail() {
        let wakeID = UUID()
        let acceptedAt = Date(timeIntervalSince1970: 1234)
        let row = AgentChatItem.laneUpdateAutoWake(wakeID: wakeID, acceptedAt: acceptedAt)
        XCTAssertEqual(row.id, wakeID, "duplicate acceptance callbacks dedupe by identity")
        XCTAssertEqual(row.timestamp, acceptedAt)
        XCTAssertEqual(row.kind, .system, "RepoPrompt started this turn and must not claim authorship")
        XCTAssertTrue(row.text.hasPrefix("[lane-update]"))
        for forbidden in [wakeID.uuidString, "preview", "session_id", "/Users/"] {
            XCTAssertFalse(row.text.contains(forbidden))
        }
    }

    // MARK: - Coordinator

    /// Enabling is what arms the wake, and the reservation is visible where readiness is computed.
    ///
    /// Driven through `agentSessionLinkPublishPassiveStatusNotices` — the same endpoint-addressed
    /// hook the bridge publishes through — so this exercises the real scheduling gate rather than a
    /// test-only entry point.
    func testDeliverableContentReservesExactlyOneWakeOnlyWhenTheSettingIsOn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        // Setting off: content is collected and delivered naturally, but nothing is reserved.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(reserved.queueRevision, 2)

        // A newer revision raises the high-water mark of the one attempt rather than starting a
        // second: an observer reserves at most one automatic follow-up.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        let absorbed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(absorbed.wakeID, reserved.wakeID)
        XCTAssertEqual(absorbed.queueRevision, 3)
    }

    func testPostCompositionAttentionIsNotRecordedAsAttemptedAndIsNotSuppressed() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertTrue(try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.isEmpty)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            attentionRequests: [attention]
        )

        let absorbed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(absorbed.wakeID, reserved.wakeID)
        XCTAssertEqual(absorbed.wakeFingerprint.attentionOccurrences, [attention.occurrence])
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        let dispatching = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertTrue(
            try XCTUnwrap(dispatching.attemptedFingerprint).attentionOccurrences.isEmpty,
            "only attention present in the immutable rendered claim may count as attempted"
        )

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )

        XCTAssertTrue(
            try XCTUnwrap(fixture.session.oversight.suppressedWakeFingerprint)
                .attentionOccurrences.isEmpty,
            "post-composition attention may not be failure-suppressed"
        )
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "ambiguous settlement must drain the one owed reevaluation"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.wakeFingerprint.attentionOccurrences, [attention.occurrence])
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
    }

    func testMetadataRefreshDoesNotInvalidateRenderedStatusAcquisitionBasis() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.first?.changeSequence, 1)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            metadataSequenceOffset: 10,
            latestVisibleAssistantPreview: "Fresher metadata."
        )
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeFingerprint,
            reserved.wakeFingerprint,
            "presentation-only refresh must not change the status occurrence fingerprint"
        )

        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testCrowdedAutoWakeClaimCarriesItsRequiredFirstAttentionOccurrence() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let required = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0, 1],
            latestVisibleAssistantPreview: String(repeating: "<&🙂", count: 8000),
            attentionRequests: [required]
        )

        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, required.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        XCTAssertLessThanOrEqual(
            claim.fragment.utf8.count,
            AgentSessionLinkPrompts.maximumRenderedBytes
        )
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.first,
            required.occurrence
        )
    }

    /// Acceptance of a budgeted subset republishes the reduced authoritative queue immediately. The
    /// remaining rows must therefore reserve their own wake without waiting for another target edge.
    func testAcceptedPartialBatchReceiptRepublicationReservesSuccessorWakeWithoutAnotherEdge() throws {
        let fixture = try makeFixture()
        let targetIndices = Array(0 ..< 9)
        try publishInventory(fixture, revision: 1, targetCount: targetIndices.count)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let queueEpoch = UUID()
        let richText = String(repeating: "<&é🙂\"'", count: 180)
        let waitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: richText,
            declaredAt: Date(timeIntervalSince1970: 50)
        ))
        func samples(_ status: AgentSessionLinkPassiveStatusNotices.Status) ->
            [AgentSessionLinkPassiveStatusNotices.Sample]
        {
            targetIndices.map { index in
                AgentSessionLinkPassiveStatusNotices.Sample(
                    reference: Self.laneReference(index),
                    targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index),
                    displayName: richText,
                    status: status,
                    idleForSend: status == .idle,
                    waitingOn: waitingOn,
                    latestVisibleAssistantPreview: richText
                )
            }
        }

        var notices = AgentSessionLinkPassiveStatusNotices(
            observerEndpoint: endpoint,
            queueEpoch: queueEpoch
        )
        notices.enable(samples: samples(.running), linkSetRevision: 1)
        notices.setAutoWakeLanes(targetIndices.map { index in
            AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                reference: Self.laneReference(index),
                targetEndpoint: Self.laneTargetEndpoint(index),
                targetSessionID: Self.targetID(index),
                isEffectivelySelected: true
            )
        })
        for index in targetIndices {
            XCTAssertEqual(
                notices.requestAttention(
                    reference: Self.laneReference(index),
                    targetEndpoint: Self.laneTargetEndpoint(index),
                    targetSessionID: Self.targetID(index),
                    linkSetRevision: 1,
                    requestedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                ),
                .accepted
            )
        }
        notices.reconcile(
            samples: samples(.idle),
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let offeredCount = notices.snapshot.entries.count + notices.snapshot.attentionRequests.count
        XCTAssertEqual(offeredCount, targetIndices.count * 2)
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            notices.snapshot,
            to: endpoint
        )

        let firstAttempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        firstAttempt.task?.cancel()
        let firstClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: firstAttempt.wakeID)
        ))
        let firstReceipt = try XCTUnwrap(firstClaim.passive).receipt
        let firstDeliveredCount = firstReceipt.deliveredStatuses.count
            + firstReceipt.deliveredAttentionOccurrences.count
        XCTAssertGreaterThan(firstDeliveredCount, 0)
        XCTAssertLessThan(firstDeliveredCount, offeredCount, "the rich queue must be budgeted")

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(firstClaim)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // `publishLane` fixtures intentionally inject already-reduced snapshots, so mirror only the
        // runtime bridge's synchronous receipt body here: apply the accepted exact-subset receipt and
        // republish that reducer's resulting snapshot. This is receipt settlement, not a new target
        // activity publication.
        notices.apply(firstReceipt)
        let remaining = notices.snapshot
        XCTAssertEqual(
            remaining.entries.count + remaining.attentionRequests.count,
            offeredCount - firstDeliveredCount
        )
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(remaining, to: endpoint)

        let successor = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "receipt republication must re-admit the deferred rows without another target edge"
        )
        successor.task?.cancel()
        XCTAssertNotEqual(successor.wakeID, firstAttempt.wakeID)
        XCTAssertEqual(successor.queueRevision, remaining.queueRevision)
        let successorClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: successor.wakeID)
        ))
        let successorReceipt = try XCTUnwrap(successorClaim.passive).receipt
        XCTAssertTrue(Set(firstReceipt.deliveredAttentionOccurrences).isDisjoint(
            with: successorReceipt.deliveredAttentionOccurrences
        ))
        XCTAssertTrue(Set(firstReceipt.deliveredStatuses).isDisjoint(
            with: successorReceipt.deliveredStatuses
        ))
    }

    func testSuppressedStatusCannotSaveAttentionThatEscapedSuppressionButWasOmitted() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressedWakeFingerprint = failedStatus.wakeFingerprint

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "exact purposeful attention may re-arm an otherwise suppressed status shape"
        )
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)

        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
            dispatchID: .autoWake(wakeID: reserved.wakeID),
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            render: { request in
                AgentSessionLinkPromptRenderResult(
                    fragment: "[attention omitted]",
                    passiveBatch: .init(
                        entries: request.passiveNotices?.entries ?? [],
                        attentionRequests: [],
                        overflowProducedThrough: request.passiveNotices?.overflowProduced ?? 0,
                        includesUnattributedOverflow: false
                    )
                )
            }
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint,
            failedStatus.wakeFingerprint
        )
    }

    func testPurposefulAttentionIgnoresRoutineSelectionWhenRearmingSuppressedStatus() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0],
            laneIndices: [0, 1],
            selectedTargetIndices: [0]
        )
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressedWakeFingerprint = failedStatus.wakeFingerprint

        let attention = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0],
            laneIndices: [0, 1],
            selectedTargetIndices: [0],
            attentionRequests: [attention]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "purposeful attention must bypass lane-one's routine deselection"
        )
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
    }

    func testRenderedAttentionThatFailedIsSuppressedAndRemainsOwedForNaturalTurn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )

        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint?.attentionOccurrences,
            [attention.occurrence]
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the same failed attention occurrence must not loop automatically"
        )
        let naturalClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .claudeNativeSend(UUID())
        ))
        XCTAssertEqual(
            try XCTUnwrap(naturalClaim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence],
            "failure suppression never discards natural-turn delivery"
        )
    }

    func testNewAttentionRearmsFailedAttentionAndIsTheExactRequiredBasis() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let failedAttention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention]
        )
        let failed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failed.task?.cancel()
        let failedClaim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: failed.wakeID)
        ))
        var failedPreparing = failed
        failedPreparing.phase = .preparingDispatch
        failedPreparing.task = nil
        fixture.session.oversight.pendingAutoWake = failedPreparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: failedClaim.dispatchID
        ))
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: failedClaim.dispatchID
        )

        let successor = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention, successor]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a new exact occurrence may re-arm an older failed occurrence"
        )
        reserved.task?.cancel()
        XCTAssertEqual(
            reserved.requiredAttentionOccurrence,
            successor.occurrence,
            "the newly admitting occurrence, not the older pending failure, owns the bypass"
        )

        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let incompleteClaim = try XCTUnwrap(
            fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
                dispatchID: .autoWake(wakeID: reserved.wakeID),
                epoch: context.epoch,
                inventory: context.inventory,
                passiveNotices: context.passiveNotices,
                render: { _ in
                    AgentSessionLinkPromptRenderResult(
                        fragment: "[only the failed occurrence fit]",
                        passiveBatch: .init(
                            entries: [],
                            attentionRequests: [failedAttention],
                            overflowProducedThrough: 0,
                            includesUnattributedOverflow: false
                        )
                    )
                }
            )
        )
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: incompleteClaim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
    }

    func testNewPurposefulAttentionIgnoresRoutineSelectionWhenRearmingOlderFailure() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let failedAttention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            attentionRequests: [failedAttention]
        )
        let failed = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failed.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failed.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressedWakeFingerprint = failed.wakeFingerprint

        fixture.session.oversight.autoWakeOnUpdates = false
        let successor = Self.attentionRequest(1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0],
            attentionRequests: [failedAttention, successor]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a new purposeful occurrence may re-arm an older failure despite routine deselection"
        )
        reserved.task?.cancel()
        XCTAssertEqual(
            reserved.requiredAttentionOccurrence,
            successor.occurrence,
            "the newly admitting exact occurrence owns the routine-policy bypass"
        )
    }

    func testAttentionSuppressionDoesNotChangeTheMutableStatusAcquisitionRace() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let failedStatus = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        failedStatus.task?.cancel()
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: failedStatus.observerEndpoint,
            reason: .settingDisabled
        )
        fixture.session.oversight.suppressedWakeFingerprint = failedStatus.wakeFingerprint

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertNil(reserved.requiredAttentionOccurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testPurposefulAttentionBypassesOnlyItsExactLaneSnooze() throws {
        let bypass = try makeFixture()
        installSnoozeClock(bypass)
        try publishInventory(bypass, revision: 1)
        bypass.session.oversight.autoWakeOnUpdates = true
        bypass.session.runState = .running
        let bypassEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            bypass.viewModel,
            tabID: bypass.tabID
        )
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        for laneIndex in [0, 1] {
            _ = try requireSnoozeSuccess(mutateSnooze(
                bypass,
                endpoint: bypassEndpoint,
                laneIndex: laneIndex,
                command: .set(durationSeconds: 600)
            ))
        }

        let attention = Self.attentionRequest(0)
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [1],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1],
            attentionRequests: [attention]
        )
        let attentionDriven = try XCTUnwrap(
            bypass.session.oversight.pendingAutoWake,
            "purposeful attention may bypass its exact lane's snooze"
        )
        attentionDriven.task?.cancel()
        XCTAssertEqual(attentionDriven.requiredAttentionOccurrence, attention.occurrence)
        XCTAssertEqual(bypass.session.oversight.autoWakeSnoozes.count, 2)

        bypass.viewModel.cancelAgentSessionLinkAutoWake(
            for: bypassEndpoint,
            reason: .settingDisabled
        )
        try publishLane(
            bypass,
            linkSetRevision: 1,
            queueRevision: 3,
            targetIndices: [1],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        XCTAssertNil(
            bypass.session.oversight.pendingAutoWake,
            "attention for lane zero must not broadly unsnooze routine status on lane one"
        )
    }

    func testPurposefulAttentionIgnoresRoutineSelectionThroughPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)

        // Master and per-lane routine selection are now both off, with no republication. The real
        // master mutator must route through the shared live fence, retain the exact attention attempt,
        // and let physical acquisition apply the same exception rather than trusting the stale
        // routine-selection projection.
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpoint
        ))
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        var preparing = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: claim.dispatchID
        )
    }

    func testPurposefulAttentionSelectionBypassStillRequiresExactLaneGeneration() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let staleAttention = Self.attentionRequest(0)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            referenceGeneration: 2,
            attentionRequests: [staleAttention]
        )

        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "ignoring routine selection must not ignore the generation-qualified lane authority"
        )
    }

    func testPostClaimUnlinkRefusesAttentionAndOldOccurrenceCannotReplayThroughRelinkedGeneration() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.runState = .running
        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence]
        )

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        // Unlink generation 1 while its exact attention-backed claim is already reserved. Preparation
        // must become a transport tombstone rather than trusting the immutable claim's stale grant.
        try publishLane(
            fixture,
            linkSetRevision: 2,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [1],
            selectedTargetIndices: []
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // A relinked generation is a different authority. Even if a later projection still carries
        // the retired occurrence, releasing the tombstone must not replay it through generation 2.
        try publishLane(
            fixture,
            linkSetRevision: 3,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: [],
            referenceGeneration: 2,
            attentionRequests: [attention]
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        XCTAssertNil(fixture.viewModel.agentSessionLinkPromptClaimStore.pendingClaim(
            dispatchID: claim.dispatchID,
            observerSessionID: fixture.sessionID
        ))
    }

    func testBudgetOmissionOfRequiredAttentionBasisIsADefiniteNoCall() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0]
        )
        _ = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 600)
        ))
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpoint
        ))
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0],
            laneIndices: [0],
            attentionRequests: [attention]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let context = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptContext(
            for: fixture.session
        ))
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaimStore.claim(
            dispatchID: .autoWake(wakeID: reserved.wakeID),
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            render: { request in
                let renderedStatuses = request.passiveNotices?.entries ?? []
                return AgentSessionLinkPromptRenderResult(
                    fragment: "[lane-update omitted by budget]",
                    passiveBatch: .init(
                        entries: renderedStatuses,
                        attentionRequests: [],
                        overflowProducedThrough: request.passiveNotices?.overflowProduced ?? 0,
                        includesUnattributedOverflow: false
                    )
                )
            }
        ))
        XCTAssertTrue(try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences.isEmpty)
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.count, 1)

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testAttentionDrivenWakeRequiresItsReservedOccurrenceAtPhysicalAcquisition() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let first = Self.attentionRequest(0, sequence: 1)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [first]
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [first.occurrence]
        )

        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        let successor = Self.attentionRequest(0, sequence: 2)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [successor]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "refusing the stale basis must replay the successor occurrence"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.requiredAttentionOccurrence, successor.occurrence)
        XCTAssertEqual(replayed.wakeFingerprint.attentionOccurrences, [successor.occurrence])
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testOwedReevaluationIsDrainedByNotAttemptedSettlement() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let absorbedFingerprint = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake
        ).wakeFingerprint
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a definite no-call settlement must replay the absorbed publication"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.wakeFingerprint, absorbedFingerprint)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testReadyCatalogTransitionRedrivesOneOwedWakeWithoutAnotherNotice() async throws {
        let fixture = try makeFixture(catalogReady: false)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the passive publication remains owed while its current run catalog is unready"
        )

        let projection = try publishCatalogProjection(fixture, revision: 1, hasAgentSessionLink: true)
        try await AsyncTestWait.waitUntil("the ready transition to re-drive the owed wake") {
            await MainActor.run {
                fixture.session.oversight.pendingAutoWake?.phase == .awaitingSettlement
            }
        }
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)

        // Replaying the same ready projection is not a second transition and must not reserve another
        // wake. No passive status publication occurs after the one above.
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            projection,
            to: reserved.observerEndpoint
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testColdRestoredObserverSchedulesPurposefulAttentionWithoutPriorRunCatalog() throws {
        let fixture = try makeFixture(catalogReady: false)
        let priorRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(fixture.session.clearRunID(ifCurrent: priorRunID))
        try publishInventory(fixture, revision: 1)
        XCTAssertEqual(fixture.session.runState, .idle)

        let attention = Self.attentionRequest(0)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            attentionRequests: [attention]
        )

        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a cold-restored observer must be able to bootstrap the run that creates its catalog"
        )
        reserved.task?.cancel()
        XCTAssertNil(fixture.session.runID)
        XCTAssertEqual(reserved.requiredAttentionOccurrence, attention.occurrence)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(
            try XCTUnwrap(claim.passive).receipt.deliveredAttentionOccurrences,
            [attention.occurrence]
        )
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testColdRestoredRoutineWakeStillRequiresSelection() throws {
        let fixture = try makeFixture(catalogReady: false)
        let priorRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertTrue(fixture.session.clearRunID(ifCurrent: priorRunID))
        try publishInventory(fixture, revision: 1)
        XCTAssertEqual(fixture.session.runState, .idle)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "cold restoration must not broaden routine Auto-wake admission"
        )

        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "a selected routine update must bootstrap a cold-restored observer"
        )
        reserved.task?.cancel()
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertEqual(try XCTUnwrap(claim.passive).receipt.deliveredStatuses.count, 1)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testBusyWakeAwaitsOneCancellableObservationSubscription() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let parked = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(parked.phase, .awaitingSettlement)
        XCTAssertNotNil(parked.task, "busy reevaluation must own the awaited readiness subscription")
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: parked.observerEndpoint,
            reason: .settingDisabled
        )
        XCTAssertTrue(parked.task?.isCancelled == true)
    }

    func testQueueSideCompetitionCannotEraseDispatchingWakeIdentity() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            requiredAttentionOccurrence: reserved.requiredAttentionOccurrence,
            attemptedFingerprint: reserved.wakeFingerprint,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])

        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            fixture.session.oversight.suppressedWakeFingerprint,
            reserved.wakeFingerprint
        )
    }

    /// The pipeline the product ruling exists to allow: wake, accept, new edge, wake again — with no
    /// local user turn anywhere in between.
    ///
    /// Each accepted wake used to leave the observer on a non-local origin that only a fresh human
    /// utterance could clear, so a delegated multi-stage pipeline stalled at the *second* Auto-wake
    /// even though the user had already granted and selected the lane. Admission is now decided by
    /// selection, snooze, and whether a genuinely new edge exists.
    func testRepeatedAutonomousWakesAdmitWithoutAnyInterveningLocalUserTurn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true

        var queueRevision: UInt64 = 0
        var edgeOffset: UInt64 = 0
        var acceptedWakeIDs: [UUID] = []
        for wakeNumber in 1 ... 3 {
            queueRevision += 1
            edgeOffset += 10
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: queueRevision,
                edgeSequenceOffset: edgeOffset
            )
            let attempt = try XCTUnwrap(
                fixture.session.oversight.pendingAutoWake,
                "wake \(wakeNumber) must be admitted by its own new edge"
            )

            // Accepted exactly as a provider would, through the claim that carries its identity.
            let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
                for: fixture.session,
                dispatchID: .autoWake(wakeID: attempt.wakeID)
            ))
            fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
            acceptedWakeIDs.append(attempt.wakeID)
            XCTAssertNil(
                fixture.session.oversight.pendingAutoWake,
                "wake \(wakeNumber) must settle on acceptance"
            )
        }

        XCTAssertEqual(Set(acceptedWakeIDs).count, 3, "each wake has its own identity")
        for wakeID in acceptedWakeIDs {
            XCTAssertEqual(
                fixture.session.items.count(where: { $0.id == wakeID }),
                1,
                "each accepted wake leaves exactly one visible provenance row"
            )
        }
    }

    /// Two independently granted, independently selected directions each keep waking on their own
    /// new routine status edges — and routine selection is what stops one of them.
    ///
    /// This is the accepted product consequence of the deletion, pinned rather than papered over.
    /// Neither grant implies the other; the user created both. The transport deliberately encodes no
    /// reciprocal detector, cycle counter, or cooldown. Per-lane snooze and Auto-wake deselection stop
    /// this routine status churn; exact purposeful attention may bypass both, while unlink remains the
    /// hard control for that signal. This test exercises only the routine-status half.
    func testReciprocalRoutineStatusEdgesStopWhenOneDirectionIsDeselected() throws {
        let observerA = try makeFixture()
        let observerB = try makeFixture()
        for fixture in [observerA, observerB] {
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
        }

        // Round 1: each direction's own new edge admits its own wake.
        try publishLane(observerA, linkSetRevision: 1, queueRevision: 1, edgeSequenceOffset: 10)
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 1, edgeSequenceOffset: 10)
        let wakeA1 = try XCTUnwrap(observerA.session.oversight.pendingAutoWake).wakeID
        let wakeB1 = try XCTUnwrap(observerB.session.oversight.pendingAutoWake).wakeID
        try acceptWake(observerA, wakeID: wakeA1)
        try acceptWake(observerB, wakeID: wakeB1)

        // Round 2: each accepted wake is itself a lifecycle change the *other* side observes, and
        // that genuinely new edge admits again. No local user turn happened anywhere.
        try publishLane(observerA, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 20)
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 20)
        let wakeA2 = try XCTUnwrap(
            observerA.session.oversight.pendingAutoWake,
            "reciprocal churn is an accepted consequence, not something the transport damps"
        ).wakeID
        XCTAssertNotEqual(wakeA2, wakeA1)
        XCTAssertNotNil(observerB.session.oversight.pendingAutoWake)
        try acceptWake(observerA, wakeID: wakeA2)
        let wakeB2 = try XCTUnwrap(observerB.session.oversight.pendingAutoWake).wakeID
        try acceptWake(observerB, wakeID: wakeB2)

        // The user applies a control to one direction only.
        let endpointA = try AgentSessionLinkEndpointTestSupport.endpoint(
            observerA.viewModel,
            tabID: observerA.tabID
        )
        XCTAssertTrue(observerA.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
            false,
            for: endpointA
        ))
        observerA.session.oversight.autoWakeTargetSessionIDs = []

        try publishLane(
            observerA,
            linkSetRevision: 1,
            queueRevision: 3,
            edgeSequenceOffset: 30,
            selectedTargetIndices: []
        )
        try publishLane(observerB, linkSetRevision: 1, queueRevision: 3, edgeSequenceOffset: 30)

        XCTAssertNil(
            observerA.session.oversight.pendingAutoWake,
            "deselecting Auto-wake must stop later admission for that direction"
        )
        XCTAssertNotNil(
            observerB.session.oversight.pendingAutoWake,
            "a control on one direction must not silence the other"
        )
    }

    /// Accepts one wake through the real claim path, exactly as a provider's acceptance signal does.
    private func acceptWake(_ fixture: Fixture, wakeID: UUID) throws {
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID)
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "an accepted wake settles")
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == wakeID }),
            1,
            "each accepted wake leaves exactly one visible provenance row"
        )
    }

    /// Master off plus an unselected lane is the combination that must stay silent, and selecting
    /// that same lane is what makes its next update wake-eligible.
    func testMasterOffLeavesAnUnselectedLaneSilentUntilThatLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "an unselected lane must not reserve a turn while the master switch is off"
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(
            fixture.session.oversight.pendingAutoWake,
            "a granular selection is sufficient on its own"
        )
    }

    /// Overflow is a whole-queue count, never attributed to the lane that produced it.
    ///
    /// Regression: "some lane is selected" was enough for overflow to reserve a wake, so dropped
    /// edges belonging to an excluded target started an autonomous turn — the selected lane's only
    /// contribution being that it existed.
    func testOverflowFromAnUnselectedLaneCannotWakeMerelyBecauseAnotherLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = false
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)

        // No entries at all, so the unattributed overflow is the only thing that could trigger a
        // wake — and one of the two live lanes is excluded from Auto-wake.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )

        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "overflow that may have come from an excluded lane must not reserve a turn"
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "refusing to wake is not discarding the queue: the overflow stays owed to a natural turn"
        )
    }

    /// The conservative rule is not "overflow never wakes": once every live lane is selected, the
    /// dropped edges provably belong to lanes the user opted in to.
    ///
    /// Scheduling and the acceptance fence must apply the identical predicate, so an attempt admitted
    /// under "every lane selected" stops qualifying the moment one of them is excluded.
    func testOverflowWakesOnlyWhenEveryLiveLaneIsSelectedAndTheFenceAppliesTheSameRule() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0, 1]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "overflow across a fully selected lane set is wake-eligible"
        )

        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        fixture.session.oversight.autoWakeTargetSessionIDs = [Self.targetID(0)]

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // Master-on satisfies the rule by construction, so the whole-observer case keeps waking on
        // overflow alone even while the granular set is a strict subset.
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)
    }

    /// Selection is live session state; the lane flag in a published snapshot is only the projection
    /// of it that publication froze, and the two disagree for exactly as long as a refresh takes.
    ///
    /// Regression: the acceptance fence read that projection, so a lane the user deselected while a
    /// wake was already preparing could still cross the provider transport boundary and start a turn
    /// nobody asked for.
    func testDeselectingALaneRefusesItsWakeAtTheAcceptanceFenceBeforeAnyRepublication() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        // Deselected with no republication: the snapshot the fence used to consult still reports the
        // lane as selected, so only a live read can refuse this.
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?
                .autoWakeLanes.map(\.isEffectivelySelected),
            [true],
            "precondition: the published projection has not caught up with the deselection"
        )

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// The same live selection is what makes the mutation itself retract an attempt, rather than
    /// leaving a deselected lane's wake alive until something else happens to re-evaluate it.
    func testDeselectingALaneRetractsAScheduledWakeSynchronously() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([], for: endpoint))

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "deselecting stops scheduling; it does not discard the queue"
        )
    }

    /// Once selection retracts a preparing attempt, later selection writes cannot release its transport
    /// tombstone. Only a path that proves the provider call did not occur may retire that identity.
    func testRepeatedSelectionChangesDoNotClearPreDispatchTombstone() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0],
            laneIndices: [0],
            selectedTargetIndices: []
        )
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [Self.targetID(0)],
            for: endpoint
        ))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([], for: endpoint))
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeID,
            reserved.wakeID,
            "repeated selection loss must not clear the dispatch-ID fence"
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the refused physical boundary safely releases the tombstone"
        )
    }

    /// Selecting a lane makes its *next* update wake-eligible and changes nothing retroactively.
    ///
    /// Selection is read live rather than from the lane's frozen projection, so a freshly selected
    /// lane does not have to wait for an authoritative republication to become eligible — and an
    /// already-published edge that predates the selection does not manufacture a turn either.
    func testSelectingALaneMakesItsNextUpdateEligibleWithoutRetroactiveWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        // The lane is live and unselected, with no queued edge yet.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            selectedTargetIndices: []
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [Self.targetID(0)],
            for: endpoint
        ))
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "selecting a lane must not retroactively wake on state that already existed"
        )

        // The lane's next genuine edge is eligible under the new selection.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)
    }

    /// Drives the real waiting-instruction continuation from suspension through lane acceptance.
    /// The returned origin, user-activity timestamp, and transcript authorship are the observable
    /// contract that distinguishes this from an ordinary user answer.
    func testWaitingContinuationPreservesSystemOriginWithoutUserAttribution() async throws {
        let fixture = try makeFixture()
        // This assertion also covers Claude's non-Codex token accounting; the generic fixture uses
        // OpenCode only to keep unrelated exact-catalog readiness out of admission tests.
        fixture.session.selectedAgent = .claudeCode
        #if DEBUG
            let projection = try publishCatalogProjection(
                fixture,
                revision: 2,
                hasAgentSessionLink: true
            )
            let routeToken = try XCTUnwrap(projection.routeToken)
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in
                routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
                candidate == routeToken && tabID == fixture.tabID
            }
        #endif
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let priorUserActivity = Date(timeIntervalSince1970: 123)
        fixture.session.lastUserMessageAt = priorUserActivity
        fixture.session.activeNonCodexTurnTokenAccumulator = .init()
        let userRowsBefore = fixture.session.items.count(where: { $0.kind == .user })

        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(
                tabID: fixture.tabID,
                prompt: "What next?",
                timeoutSeconds: 5
            )
        }
        for _ in 0 ..< 20 where fixture.session.instructionContinuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.session.instructionContinuation)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let response = try await waiting.value
        guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
            return XCTFail("expected the waiting continuation to preserve lane-update origin")
        }

        XCTAssertEqual(fixture.session.lastUserMessageAt, priorUserActivity)
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), userRowsBefore)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID && $0.kind == .system }), 1)
        XCTAssertNil(fixture.session.instructionContinuation)
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertEqual(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens,
            0
        )
        XCTAssertGreaterThan(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedToolInputTokens ?? 0,
            0,
            "system-origin continuation text still consumes provider context"
        )
    }

    /// Purposeful attention must survive Codex's exact-catalog readiness suspension, reserve the
    /// same immutable claim as the idle route, and cross the shared physical-acquisition fence before
    /// the existing waiting continuation resumes.
    func testCodexWaitingContinuationCarriesPurposefulAttentionThroughReadinessClaimAndAcquisition() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.session.selectedAgent = .codexExec
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            defer {
                fixture.session.instructionTimeoutTask?.cancel()
                fixture.session.instructionTimeoutTask = nil
                fixture.session.instructionContinuation?.resume(throwing: CancellationError())
                fixture.session.instructionContinuation = nil
                fixture.session.instructionWaitID = nil
                fixture.session.waitingPrompt = nil
                withExtendedLifetime(controller) {}
            }

            let authorityGate = AutoWakeCatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            let projection = try publishCatalogProjection(
                fixture,
                revision: 2,
                hasAgentSessionLink: true
            )
            let routeToken = try XCTUnwrap(projection.routeToken)
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == routeToken.runID,
                      requestedWindowID == routeToken.observerEndpoint.windowID,
                      requestedTabID == routeToken.observerEndpoint.tabID
                else { return nil }
                return routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
                candidate == routeToken && tabID == fixture.tabID
            }
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true
            let userRowsBefore = fixture.session.items.count(where: { $0.kind == .user })

            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    prompt: "What next?",
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the Codex continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }

            let attention = Self.attentionRequest(0)
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: 1,
                targetIndices: [],
                laneIndices: [0],
                attentionRequests: [attention]
            )
            await authorityGate.waitUntilEntered()
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.requiredAttentionOccurrence,
                attention.occurrence
            )
            XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(
                false,
                for: routeToken.observerEndpoint
            ))
            XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
            XCTAssertTrue(fixture.session.oversight.autoWakeTargetSessionIDs.isEmpty)
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.requiredAttentionOccurrence,
                attention.occurrence,
                "routine deselection during readiness suspension must retain exact purposeful attention"
            )
            XCTAssertNotNil(
                fixture.session.instructionContinuation,
                "readiness must settle before attention claim selection and acquisition"
            )
            await authorityGate.open()

            let response = try await waiting.value
            guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
                return XCTFail("expected purposeful attention to resume with lane-update origin")
            }
            let providerText = try XCTUnwrap(response.text)
            XCTAssertTrue(providerText.contains(
                "<attention_request session_id=\"\(attention.targetSessionID.uuidString)\""
            ))
            XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), userRowsBefore)
            XCTAssertEqual(
                fixture.session.items.count(where: { $0.id == wakeID && $0.kind == .system }),
                1
            )
            XCTAssertNil(fixture.session.instructionContinuation)
            XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testCodexWaitingAutoWakeReadinessSupersessionSettlesAttemptWithoutDispatch() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.session.selectedAgent = .codexExec
            let authorityGate = AutoWakeCatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            try publishInventory(fixture, revision: 1)
            fixture.session.oversight.autoWakeOnUpdates = true

            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the auto-wake continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { routeToken, tabID in
                routeToken.runID == runID
                    && routeToken.observerEndpoint == endpoint
                    && tabID == fixture.tabID
            }
            let itemCount = fixture.session.items.count

            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
            await authorityGate.waitUntilEntered()
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let unready = await ServerNetworkManager.shared.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)
            await authorityGate.open()
            try await AsyncTestWait.waitUntil("the auto-wake catalog waiter to register") {
                await ServerNetworkManager.shared.debugHasRunCatalogState(for: runID)
            }
            await ServerNetworkManager.shared.cleanupRunRoutingState(
                for: runID,
                windowID: endpoint.windowID
            )

            try await AsyncTestWait.waitUntil("the superseded auto-wake attempt to settle") {
                await MainActor.run { fixture.session.oversight.pendingAutoWake == nil }
            }
            XCTAssertNotNil(fixture.session.instructionContinuation)
            XCTAssertEqual(fixture.session.items.count, itemCount)
            XCTAssertFalse(
                fixture.session.items.contains { $0.id == attempt.wakeID },
                "no provider-accepted auto-wake row may be written"
            )
            // Tear the wait down the way the production path does. Resuming the continuation without
            // also cancelling the timeout task leaves a 10-second timer armed against a continuation
            // that has already been consumed, and it fires long after this test ends — crashing
            // whichever unrelated test happens to be running with a checked-continuation misuse.
            fixture.session.instructionTimeoutTask?.cancel()
            fixture.session.instructionTimeoutTask = nil
            fixture.session.instructionContinuation?.resume(throwing: CancellationError())
            fixture.session.instructionContinuation = nil
            fixture.session.instructionWaitID = nil
            fixture.session.waitingPrompt = nil
            _ = try? await waiting.value
            withExtendedLifetime(controller) {}
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    /// Natural delivery that clears the queue cancels the reservation, with no provider call and no
    /// transcript row.
    func testNaturalDeliveryCancelsAPendingWakeWithoutAProvenanceRow() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let itemsBefore = fixture.session.items.count
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemsBefore, "a cancelled wake writes no row")
    }

    /// Turning the setting off releases an unaccepted reservation but never clears the lane queue:
    /// the content stays owed to a natural future turn.
    func testTurningTheSettingOffReleasesTheReservationAndLeavesTheQueueOwed() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.oversight.pendingAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(
            fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint)
        )
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertFalse(fixture.session.oversight.autoWakeOnUpdates)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "turning off scheduling is not discarding the queue"
        )
    }

    /// Off/on is failure recovery: it clears suppression without inventing an admission basis.
    func testExplicitOffOnCycleClearsFailureSuppressionWithoutInventingAdmission() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let fingerprint = Self.laneSnapshot(
            observerEndpoint: endpoint,
            queueRevision: 1
        ).wakeEligibilityFingerprint
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        fixture.session.oversight.suppressedWakeFingerprint = fingerprint

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))

        // Master off with no per-lane selection: nothing is selected, so nothing may admit.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "an unselected lane may not admit a wake"
        )

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: endpoint))
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "an explicit off/on cycle clears a failed attempt's suppression"
        )
    }

    /// Accepting a wake's claim settles the attempt, writes exactly one row, and is idempotent.
    ///
    /// Acceptance is keyed on the claim's own dispatch identity, so this is the same path every
    /// provider family reaches through its existing physical-acceptance signal.
    func testAcceptedWakeSettlesTheAttemptAndWritesExactlyOneSystemRowIdempotently() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let wakeID = try XCTUnwrap(fixture.session.oversight.pendingAutoWake).wakeID

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID)
        ))
        XCTAssertNotNil(claim.passive, "a wake claim always carries the batch it exists for")

        let itemsBefore = fixture.session.items.count
        let nextSequenceIndex = fixture.session.nextSequenceIndex
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        let appended = fixture.session.items.suffix(from: itemsBefore)
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.id, wakeID)
        XCTAssertEqual(appended.first?.kind, .system)
        XCTAssertEqual(appended.first?.sequenceIndex, nextSequenceIndex)
        XCTAssertFalse(
            fixture.session.items.contains { $0.kind == .user && $0.id == wakeID },
            "a wake never impersonates the user"
        )

        // Duplicate acceptance callbacks are idempotent by wake ID.
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID }), 1)
    }

    /// A late or duplicate acceptance stays truthful without reclaiming anything.
    ///
    /// The user submitted after this wake crossed its physical boundary, so the wake genuinely did
    /// run and its provenance row is recorded — exactly once, keyed by wake ID. There is no origin
    /// state left for a late callback to overwrite, and replaying the same claim adds nothing.
    func testLateAndDuplicateAcceptanceRecordProvenanceExactlyOnce() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            requiredAttentionOccurrence: reserved.requiredAttentionOccurrence,
            attemptedFingerprint: reserved.wakeFingerprint,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        // The local user wins the submission gate after the wake was already dispatching.
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .localUserWon
        )

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == reserved.wakeID }),
            1,
            "a late acceptance still records the turn that really happened, exactly once"
        )

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.id == reserved.wakeID }),
            1,
            "replaying the same claim adds nothing"
        )
    }

    func testAmbiguousFailureSuppressesOnlyThePhysicallyAttemptedFingerprint() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var dispatching = reserved
        dispatching.phase = .dispatching
        dispatching.attemptedFingerprint = reserved.wakeFingerprint
        dispatching.physicalOutcome = .ambiguous
        fixture.session.oversight.pendingAutoWake = dispatching

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [1],
            edgeSequenceOffset: 10
        )
        let newerFingerprint = try XCTUnwrap(fixture.session.oversight.pendingAutoWake).wakeFingerprint
        XCTAssertNotEqual(newerFingerprint, reserved.wakeFingerprint)

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        )
        XCTAssertEqual(fixture.session.oversight.suppressedWakeFingerprint, reserved.wakeFingerprint)
        XCTAssertNotEqual(fixture.session.oversight.suppressedWakeFingerprint, newerFingerprint)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "ambiguous delivery must leave the lane receipt unacknowledged"
        )
    }

    func testEmptiedQueueDoesNotClearAStandingTombstoneAndAttentionReplaysOnRelease() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        let tombstone = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(tombstone.phase, .cancelledBeforeDispatch)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3, targetIndices: [])
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.wakeID,
            tombstone.wakeID,
            "a second empty publication must not clear the dispatch-ID fence"
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        let replacementEpoch = try XCTUnwrap(UUID(
            uuidString: "0000000F-0000-0000-0000-000000005502"
        ))
        let attention = Self.attentionRequest(0, queueEpoch: replacementEpoch)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            queueEpoch: replacementEpoch,
            attentionRequests: [attention]
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, tombstone.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertTrue(fixture.session.oversight.autoWakeReevaluationOwed)

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        let replayed = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "releasing the tombstone must drain attention absorbed while it stood"
        )
        XCTAssertNotEqual(replayed.wakeID, reserved.wakeID)
        XCTAssertEqual(replayed.requiredAttentionOccurrence, attention.occurrence)
        XCTAssertFalse(fixture.session.oversight.autoWakeReevaluationOwed)
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
    }

    func testPreparingCancellationKeepsFinalizerAndSettlesWithoutConsumingLane() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        let finalizer = Task { @MainActor in }
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = finalizer
        fixture.session.oversight.pendingAutoWake = preparing
        let itemCount = fixture.session.items.count

        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )

        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(finalizer.isCancelled, "preparing cancellation must not cancel its only finalizer")

        let dispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )

        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemCount, "a pre-call cancellation writes no provider error or provenance row")
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "the unaccepted lane batch remains owed"
        )

        fixture.session.runState = .idle
        let readiness = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: fixture.session,
            endpointMatchesGrant: true,
            isClosing: false
        )
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness), .ready)
    }

    /// An ordinary turn that happens to carry a lane batch is not a wake.
    ///
    /// It acknowledges the queue exactly as before, but it must not claim lane-update origin and must
    /// not write a provenance row for a turn the user started.
    func testAnOrdinaryDispatchCarryingALaneBatchIsNotTreatedAsAWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .claudeNativeSend(UUID())
        ))
        XCTAssertNotNil(claim.passive)
        let itemsBefore = fixture.session.items.count
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertEqual(
            fixture.session.items.count,
            itemsBefore,
            "an ordinary dispatch must not write a wake provenance row"
        )
    }

    // MARK: - Auto-wake snooze

    /// The canonical contract: a snoozed sole lane suppresses admission and nothing else, and its
    /// deadline re-drives the *retained* snapshot rather than fabricating one.
    func testSnoozedSoleLaneBlocksAdmissionUntilItsDeadlineRedrivesTheRetainedSnapshot() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        // Parked rather than dispatched: this test is about admission, not about the provider route.
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        // Activation publication: the lane is live and selectable, and nothing is owed yet.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        let snoozed = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(snoozed.change, .snoozed)
        XCTAssertEqual(snoozed.projection?.remainingSeconds, 600)
        XCTAssertEqual(snoozed.projection?.origin, .user)
        XCTAssertFalse(snoozed.currentDispatchAlreadyStarted)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "the only selected lane is snoozed, so nothing may admit an automatic turn"
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "a snooze suppresses admission; it never discards, receipts, or baselines the queue"
        )
        XCTAssertNil(fixture.session.oversight.suppressedWakeFingerprint)
        let retainedRevision = fixture.viewModel
            .agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.queueRevision

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the deadline to re-drive the retained snapshot") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake != nil }
        }
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty, "the due record is removed")
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?.queueRevision,
            retainedRevision,
            "expiry reevaluates the accumulated snapshot; it never fabricates a status edge"
        )
    }

    /// The product promise stated directly: updates that pile up across *several* lanes while they
    /// are snoozed are all still there when the deadline re-drives, and the wake that follows carries
    /// every one of them rather than only the change that happened to arrive last.
    ///
    /// "A summary of all that was missed" means the queue's ordinary coalesced summary — one
    /// first-to-final interval per lane — which is the only thing the reducer has ever retained. It
    /// is deliberately not a replay of every intermediate transition.
    func testEveryLaneUpdateAccumulatedDuringASnoozeIsCarriedByTheWakeExpiryRedrives() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        // Both lanes live and selected, nothing owed yet, then both silenced.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1]
        )
        for laneIndex in [0, 1] {
            let outcome = try requireSnoozeSuccess(
                mutateSnooze(
                    fixture,
                    endpoint: endpoint,
                    laneIndex: laneIndex,
                    command: .set(durationSeconds: 600)
                )
            )
            XCTAssertEqual(outcome.change, .snoozed)
        }

        // Three successive rounds of activity while both lanes are silenced.
        for (offset, revision) in [(10, UInt64(2)), (20, 3), (30, 4)] {
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: revision,
                targetIndices: [0, 1],
                laneIndices: [0, 1],
                edgeSequenceOffset: UInt64(offset)
            )
            XCTAssertNil(
                fixture.session.oversight.pendingAutoWake,
                "every selected lane is snoozed, so none of these rounds may start a turn"
            )
        }

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("both deadlines to re-drive the accumulated snapshot") {
            await MainActor.run { fixture.session.oversight.pendingAutoWake != nil }
        }

        let attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertEqual(
            Set(attempt.wakeFingerprint.edges.map(\.reference)),
            Set([0, 1].map { Self.laneReference($0, generation: 1) }),
            "the wake expiry re-drove must account for every lane that changed while snoozed"
        )
        let snapshot = try XCTUnwrap(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]
        )
        XCTAssertEqual(
            Set(snapshot.entries.map(\.reference)),
            Set([0, 1].map { Self.laneReference($0, generation: 1) }),
            "nothing a snooze did may have removed accumulated content from the canonical queue"
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
    }

    /// Expiry is a reevaluation promise, not a delivery promise.
    func testDeadlineCreatesNoAttemptWhenTheQueueNoLongerHasDeliverableContent() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        // A natural turn receipted it, or the interval net-reverted: the lane survives, the content
        // does not.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0]
        )

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the deadline task to settle") {
            await MainActor.run { fixture.session.oversight.autoWakeSnoozes.isEmpty }
        }
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "already receipted or net-reverted content is not a still-missed message"
        )
    }

    /// The expiry race, stated directly: an elapsed record is inactive everywhere *before* the
    /// deadline task has removed it, and a read never performs the removal itself.
    func testElapsedSnoozeIsInactiveForProjectionSchedulingAndTheFinalFenceBeforeCleanup() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // The clock passes the deadline, but the deadline task is never allowed to run.
        clock.advanceWithoutFiring(seconds: 600)
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "precondition: the record is elapsed but still present"
        )

        let projection = try requireSnoozeSuccess(fixture.viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: Self.targetID(0),
            expectedReference: Self.laneReference(0)
        ))
        XCTAssertNil(projection, "an elapsed record is not an active snooze")
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "a projection read removes nothing"
        )
        XCTAssertNotNil(
            fixture.session.oversight.snoozeTaskToken,
            "a projection read cancels and re-arms nothing"
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "a projection read never re-enters the wake pipeline"
        )

        // Scheduling agrees with the read: the elapsed record cannot block the next publication.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))

        // And so does the final physical fence, which is the last gate before the transport.
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing
        XCTAssertTrue(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: claim.dispatchID
        ))
    }

    func testClearRemovesTheExactRecordAndRedrivesEvenWhenAlreadyClear() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)

        let cleared = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .clear)
        )
        XCTAssertEqual(cleared.change, .cleared)
        XCTAssertNil(cleared.projection)
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken, "no deadline remains")
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "clear performs the same immediate reevaluation the deadline would have"
        )

        // Already-clear still reevaluates: the promise is one normal-pipeline pass, not a state edge.
        fixture.viewModel.cancelAgentSessionLinkAutoWake(for: endpoint, reason: .settingDisabled)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        let alreadyClear = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .clear)
        )
        XCTAssertEqual(alreadyClear.change, .alreadyClear)
        XCTAssertNil(alreadyClear.projection)
        let requeued = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        XCTAssertNotEqual(requeued.wakeID, reserved.wakeID)
    }

    /// The cap is a per-operation remaining horizon, never a lifetime cap, and the origin follows the
    /// deadline rather than the caller.
    func testEachOperationCapsTheHorizonWhileRepeatedOperationsExtendIndefinitely() throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )

        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.defaultDurationSeconds, 600)
        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.minimumDurationSeconds, 60)
        XCTAssertEqual(AgentSessionLinkAutoWakeSnooze.maximumDurationSeconds, 3600)

        let first = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: AgentSessionLinkAutoWakeSnooze.defaultDurationSeconds),
            origin: .user
        ))
        XCTAssertEqual(first.change, .snoozed)
        XCTAssertEqual(first.projection?.remainingSeconds, 600)

        // A shorter operation cannot shorten a live snooze, and cannot take over its origin.
        let shorter = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 60),
            origin: .agent
        ))
        XCTAssertEqual(shorter.change, .alreadySnoozed)
        XCTAssertEqual(shorter.projection?.remainingSeconds, 600)
        XCTAssertEqual(shorter.projection?.origin, .user)

        clock.advanceWithoutFiring(seconds: 300)
        let extended = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 3600),
            origin: .agent
        ))
        XCTAssertEqual(extended.change, .extended)
        XCTAssertEqual(extended.projection?.remainingSeconds, 3600)
        XCTAssertEqual(extended.projection?.origin, .agent, "moving the deadline takes over the origin")

        clock.advanceWithoutFiring(seconds: 300)
        let againExtended = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            command: .set(durationSeconds: 3600),
            origin: .user
        ))
        XCTAssertEqual(againExtended.change, .extended)
        XCTAssertEqual(
            againExtended.projection?.remainingSeconds,
            3600,
            "no single operation ever leaves more than an hour on the clock"
        )
        XCTAssertEqual(againExtended.projection?.origin, .user)

        // Out-of-range requests are clamped rather than silently creating an unbounded horizon.
        let clampedLow = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            laneIndex: 1,
            command: .set(durationSeconds: 5)
        ))
        XCTAssertEqual(clampedLow.projection?.remainingSeconds, 60)
        clock.advanceWithoutFiring(seconds: 60)
        let clampedHigh = try requireSnoozeSuccess(mutateSnooze(
            fixture,
            endpoint: endpoint,
            laneIndex: 1,
            command: .set(durationSeconds: 100_000)
        ))
        XCTAssertEqual(clampedHigh.projection?.remainingSeconds, 3600)
    }

    func testSnoozeMutationRefusesAStaleGenerationWrongTargetOrRetiredObserver() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])

        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: endpoint,
                referenceGeneration: 2,
                command: .set(durationSeconds: 600)
            )),
            .staleReference,
            "a relinked generation is a different lane, not the same one"
        )
        XCTAssertEqual(
            snoozeFailure(fixture.viewModel.agentSessionLinkMutateAutoWakeSnooze(
                endpoint: endpoint,
                targetSessionID: Self.targetID(1),
                expectedReference: Self.laneReference(0),
                command: .set(durationSeconds: 600),
                origin: .agent
            )),
            .staleReference,
            "the named target must be the target this reference actually names"
        )
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration &+ 1
        )
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: superseded,
                command: .set(durationSeconds: 600)
            )),
            .observerUnavailable,
            "an in-place rebind keeps the session UUID; it must not keep the policy surface"
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty, "no refusal mutated state")

        // Set requires effective selection; clear stays available after deselection.
        fixture.session.oversight.autoWakeOnUpdates = false
        fixture.session.oversight.autoWakeTargetSessionIDs = [Self.targetID(0)]
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        fixture.session.oversight.autoWakeTargetSessionIDs = []
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))),
            .laneNotEffectivelySelected
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "a deselected lane keeps its live snooze rather than silently losing it"
        )
        XCTAssertEqual(
            try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear)).change,
            .cleared
        )
    }

    func testUnlinkAndRelinkLeaveTheNewGenerationUnsnoozed() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // Unlink: the reference is no longer current, so the record is pruned by the next publication.
        try publishLane(
            fixture,
            linkSetRevision: 2,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [1],
            selectedTargetIndices: [1]
        )
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)

        // Relink under a new generation: the replacement lane starts unsnoozed, and the retired
        // generation is not readable through it.
        try publishLane(
            fixture,
            linkSetRevision: 3,
            queueRevision: 3,
            targetIndices: [],
            laneIndices: [0],
            referenceGeneration: 2
        )
        XCTAssertNil(try requireSnoozeSuccess(fixture.viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: Self.targetID(0),
            expectedReference: Self.laneReference(0, generation: 2)
        )))
        XCTAssertEqual(
            snoozeFailure(mutateSnooze(
                fixture,
                endpoint: endpoint,
                referenceGeneration: 1,
                command: .set(durationSeconds: 600)
            )),
            .staleReference
        )
    }

    func testRebindAndTeardownRetireSnoozeStateAndItsDeadlineToken() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, targetIndices: [], laneIndices: [0])
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        // A record filed under a superseded incarnation of the same session UUID.
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration &+ 1
        )
        let supersededKey = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: superseded,
            reference: Self.laneReference(0)
        )
        fixture.session.oversight.autoWakeSnoozes[supersededKey] =
            AgentSessionLinkAutoWakeSnoozeRecord(
                key: supersededKey,
                deadline: ContinuousClock.now.advanced(by: .seconds(600)),
                origin: .agent
            )

        fixture.viewModel.agentSessionLinkPruneAutoWakeSnoozeState()
        XCTAssertNil(
            fixture.session.oversight.autoWakeSnoozes[supersededKey],
            "a replacement incarnation never inherits its predecessor's suppression"
        )
        XCTAssertEqual(fixture.session.oversight.autoWakeSnoozes.count, 1)
        XCTAssertNotNil(fixture.session.oversight.snoozeTaskToken)

        fixture.session.cancelEphemeralRuntimeState()
        XCTAssertTrue(fixture.session.oversight.autoWakeSnoozes.isEmpty)
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)
        XCTAssertNil(fixture.session.oversight.snoozeDeadlineTask)
    }

    /// Snooze suppresses *admission*, not delivery: another lane's wake still ships the snoozed lane's
    /// update, and the accepted row names it because it was rendered.
    func testAnUnsnoozedLaneAdmitsAndDeliversTheSnoozedLanesUpdate() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0, 1],
            laneIndices: [0, 1],
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0, 1]
        )
        let reserved = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "an unsnoozed lane admits the unchanged canonical batch"
        )
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        let delivered = try Set(XCTUnwrap(claim.passive).receipt.deliveredStatuses.map(\.reference))
        XCTAssertTrue(
            delivered.contains(Self.laneReference(0)),
            "the canonical batch is never filtered by snooze state"
        )
        XCTAssertTrue(delivered.contains(Self.laneReference(1)))

        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        let row = try XCTUnwrap(fixture.session.items.first { $0.id == reserved.wakeID })
        XCTAssertEqual(
            row.laneUpdateDisplayAttribution?.attributedLaneCount,
            2,
            "the accepted row names every delivered lane, hitchhikers included"
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "delivering a snoozed lane's update does not clear its snooze"
        )
    }

    func testPureOverflowCannotAdmitWhileAnyLiveLaneIsSnoozed() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0, 1]
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "unattributed overflow may have come from the lane the user just silenced"
        )

        _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        XCTAssertNotNil(
            fixture.session.oversight.pendingAutoWake,
            "with every live lane selected and unsnoozed, overflow admits on its own again"
        )
    }

    func testASnoozeDuringDispatchSucceedsWithoutRetractingThePhysicalCall() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var dispatching = reserved
        dispatching.phase = .dispatching
        dispatching.attemptedFingerprint = reserved.wakeFingerprint
        dispatching.physicalOutcome = .ambiguous
        dispatching.task = nil
        fixture.session.oversight.pendingAutoWake = dispatching

        let outcome = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(outcome.change, .snoozed)
        XCTAssertTrue(outcome.currentDispatchAlreadyStarted)
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.phase,
            .dispatching,
            "a snooze applies to later admission and never retracts a call that may be in flight"
        )

        let cleared = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        XCTAssertEqual(cleared.change, .cleared)
        XCTAssertTrue(cleared.currentDispatchAlreadyStarted)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .dispatching)
    }

    func testASnoozeRetractsAPreparingWakeAndTheFinalFenceThenRefusesIt() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(
            fixture.session.oversight.pendingAutoWake?.phase,
            .cancelledBeforeDispatch,
            "preparation owns the only finalizer that can prove no transport call happened"
        )
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// Clearing a snooze that retracted a *preparing* wake must not dismantle the provider fence.
    ///
    /// The tombstone is what keeps an in-flight provider path fenced: providers mint their own
    /// dispatch IDs, and `agentSessionLinkEffectiveDispatchID` rewrites one to the wake's identity
    /// only while an attempt exists in a dispatch phase. Retiring the tombstone to make room for a
    /// successor therefore looks like tidying up and is actually an unfencing — the still-preparing
    /// call would take the ordinary-dispatch early return and deliver the snoozed lane with no claim
    /// and no provenance row. The reevaluation a clear owes is replayed after the tombstone's own
    /// finalizer settles instead.
    func testClearingASnoozeWhileAWakePreparesKeepsTheProviderFenceIntact() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: .clear))
        // Still tombstoned, still the same identity: the clear reevaluated, and reevaluating is not a
        // licence to release a fence a provider call may still be behind.
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The load-bearing consequence: a provider's *own* dispatch ID is still rewritten to the
        // wake's, so the fence still sees it and still refuses.
        let providerDispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkEffectiveDispatchID(
                for: fixture.session,
                dispatchID: providerDispatchID
            ).autoWakeID,
            reserved.wakeID
        )
        // Asserted before the acquire, which legitimately spends the tombstone: the teardown-safe
        // restatement of the same rule has to see it too, or a teardown mid-dispatch becomes the one
        // path that lets an empty wake turn through.
        XCTAssertTrue(AgentModeViewModel.dispatchRequiresLaneBatch(
            fixture.session,
            providerDispatchID
        ))
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: providerDispatchID
        ))
        let successor = try XCTUnwrap(
            fixture.session.oversight.pendingAutoWake,
            "spending the tombstone must drain the clear reevaluation it absorbed"
        )
        XCTAssertNotEqual(successor.wakeID, reserved.wakeID)

        // The successor absorbs later queue movement rather than creating a second reservation.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, edgeSequenceOffset: 10)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, successor.wakeID)
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.queueRevision, 2)
    }

    /// Losing the admission basis a *second* time must not release the fence.
    ///
    /// The sibling test above clears the snooze, which restores the basis and never reaches the
    /// basis-lost path — so it passes either way. This one keeps the lane snoozed and publishes
    /// again, which is the ordinary case: `cancel` is not idempotent across phases, and a second
    /// cancel of an already-tombstoned attempt falls through to clearing the slot. That would delete
    /// the dispatch-ID rewrite while a provider path is still preparing, and the snoozed lane would
    /// then wake the model unfenced — no claim, no provenance row.
    func testLosingTheAdmissionBasisAgainWhileTombstonedKeepsTheFence() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The snoozed lane goes on being noisy. Every one of these re-drives the absorb branch and
        // finds no admission basis, because the only selected lane is still snoozed.
        for (offset, revision) in [(10, UInt64(2)), (20, 3)] {
            try publishLane(
                fixture,
                linkSetRevision: 1,
                queueRevision: revision,
                edgeSequenceOffset: UInt64(offset)
            )
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.wakeID,
                reserved.wakeID,
                "the tombstone must survive a repeated basis loss"
            )
            XCTAssertEqual(
                fixture.session.oversight.pendingAutoWake?.phase,
                .cancelledBeforeDispatch
            )
        }
        // An extension re-drives it too, and so does an idempotent repeat.
        for command in [
            AgentSessionLinkAutoWakeSnoozeCommand.set(durationSeconds: 1200),
            .set(durationSeconds: 60)
        ] {
            _ = try requireSnoozeSuccess(mutateSnooze(fixture, endpoint: endpoint, command: command))
            XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.wakeID, reserved.wakeID)
        }

        // The consequence the fence exists for: a provider's own dispatch ID still resolves to the
        // wake, so the still-preparing call is still refused.
        let providerDispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkEffectiveDispatchID(
                for: fixture.session,
                dispatchID: providerDispatchID
            ).autoWakeID,
            reserved.wakeID
        )
        XCTAssertTrue(AgentModeViewModel.dispatchRequiresLaneBatch(
            fixture.session,
            providerDispatchID
        ))
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: providerDispatchID
        ))
    }

    /// Kept for the acquire-side settlement of an explicitly identified wake.
    func testAcquiringATombstonedWakeByItsOwnIdentityRefusesAndReleasesIt() throws {
        let fixture = try makeFixture()
        installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        fixture.session.runState = .running
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.oversight.pendingAutoWake = preparing

        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)

        // The acquire path is the one place a tombstone is released synchronously: the provider
        // reached its transport boundary, was refused, and the identity is spent.
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: reserved.wakeID)
        ))
        XCTAssertNil(fixture.session.oversight.pendingAutoWake)
        XCTAssertNil(
            fixture.session.oversight.suppressedWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// Many records, one task: a re-arm replaces its predecessor, and the cancelled token can never
    /// expire the replacement's records.
    func testOneNearestDeadlineTaskSurvivesExtensionAndAStaleTokenCannotExpireItsReplacement() async throws {
        let fixture = try makeFixture()
        let clock = installSnoozeClock(fixture)
        try publishInventory(fixture, revision: 1)
        fixture.session.oversight.autoWakeOnUpdates = true
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            selectedTargetIndices: [0, 1]
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 600))
        )
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, laneIndex: 1, command: .set(durationSeconds: 1200))
        )
        await settleSnoozeTasks()
        XCTAssertEqual(clock.pendingSleepCount, 1, "two records still own exactly one deadline task")
        let firstToken = try XCTUnwrap(fixture.session.oversight.snoozeTaskToken)

        // Extending past the other record's deadline re-arms on the new nearest deadline.
        _ = try requireSnoozeSuccess(
            mutateSnooze(fixture, endpoint: endpoint, command: .set(durationSeconds: 3600))
        )
        await settleSnoozeTasks()
        XCTAssertEqual(clock.pendingSleepCount, 1)
        XCTAssertNotEqual(fixture.session.oversight.snoozeTaskToken, firstToken)

        clock.advance(seconds: 600)
        await settleSnoozeTasks()
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            2,
            "the cancelled 600s arming cannot expire the records its replacement owns"
        )

        clock.advance(seconds: 600)
        try await AsyncTestWait.waitUntil("the surviving deadline to expire only the due record") {
            await MainActor.run { fixture.session.oversight.autoWakeSnoozes.count == 1 }
        }
        XCTAssertNotNil(
            fixture.session.oversight.autoWakeSnoozes[AgentSessionLinkAutoWakeSnoozeKey(
                observerEndpoint: endpoint,
                reference: Self.laneReference(0)
            )],
            "the extended record survives its predecessor's deadline"
        )
        XCTAssertNotNil(
            fixture.session.oversight.snoozeTaskToken,
            "a remaining record keeps exactly one armed deadline"
        )
    }

    // MARK: - Snooze helpers

    @discardableResult
    private func installSnoozeClock(_ fixture: Fixture) -> AgentSessionLinkAutoWakeSnoozeTestClock {
        let clock = AgentSessionLinkAutoWakeSnoozeTestClock()
        fixture.session.oversight.snoozeClock = clock.clock
        return clock
    }

    private func mutateSnooze(
        _ fixture: Fixture,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        laneIndex: Int = 0,
        referenceGeneration: UInt64 = 1,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin = .user
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        fixture.viewModel.agentSessionLinkMutateAutoWakeSnooze(
            endpoint: endpoint,
            targetSessionID: Self.targetID(laneIndex),
            expectedReference: Self.laneReference(laneIndex, generation: referenceGeneration),
            command: command,
            origin: origin
        )
    }

    private func requireSnoozeSuccess<Value>(
        _ result: Result<Value, AgentSessionLinkAutoWakeSnoozeFailure>
    ) throws -> Value {
        switch result {
        case let .success(value):
            return value
        case let .failure(failure):
            XCTFail("unexpected snooze failure: \(failure.rawValue)")
            throw failure
        }
    }

    private func snoozeFailure(
        _ result: Result<some Any, AgentSessionLinkAutoWakeSnoozeFailure>
    ) -> AgentSessionLinkAutoWakeSnoozeFailure? {
        guard case let .failure(failure) = result else { return nil }
        return failure
    }

    /// Lets cancelled deadline tasks finish unwinding before their bookkeeping is asserted.
    private func settleSnoozeTasks() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture(catalogReady: Bool = true) throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee auto-wake seam"
        )
        let session = viewModel.session(for: tabID)
        // This suite owns provider-neutral admission and settlement. Exact Claude/Codex catalog
        // readiness has dedicated adapter coverage and would add an unrelated async gate here.
        session.selectedAgent = .openCode
        // Most tests establish their own explicit policy. Keep the shared fixture off so changing
        // the product's fresh-session default cannot silently change their preconditions.
        session.oversight.autoWakeOnUpdates = false
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let fixture = Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            workspaceManager: workspaceManager
        )
        if catalogReady {
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
            let runID = try XCTUnwrap(session.runID)
            viewModel.agentSessionLinkPublishRunCatalogProjection(
                AgentSessionLinkRunCatalogProjection(
                    runID: runID,
                    routeToken: AgentSessionLinkRunCatalogRouteToken(
                        runID: runID,
                        observerEndpoint: endpoint,
                        connectionID: UUID(),
                        routingAuthorityGeneration: 1,
                        connectionLifecycleGeneration: 1
                    ),
                    projectionRevision: 1,
                    hasAgentSessionLink: true
                ),
                to: endpoint
            )
        }
        return fixture
    }

    private func publishInventory(
        _ fixture: Fixture,
        revision: UInt64,
        targetCount: Int = 2
    ) throws {
        try fixture.viewModel.agentSessionLinkPublishPromptInventory(
            Self.inventory(
                observerSessionID: fixture.sessionID,
                revision: revision,
                targetCount: targetCount
            ),
            to: AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
        )
    }

    @discardableResult
    private func publishCatalogProjection(
        _ fixture: Fixture,
        revision: UInt64,
        hasAgentSessionLink: Bool
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
            hasAgentSessionLink: hasAgentSessionLink
        )
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
        return projection
    }

    private func publishLane(
        _ fixture: Fixture,
        linkSetRevision: UInt64,
        queueRevision: UInt64,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        metadataSequenceOffset: UInt64 = 0,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil,
        referenceGeneration: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch,
        latestVisibleAssistantPreview: String = "Done.",
        attentionRequests: [AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest] = []
    ) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        if let selectedTargetIndices {
            // Routine selection is live session state; the lane flag is only the projection of it
            // that this publication froze. Writing both keeps status/overflow fixtures from
            // advertising a selection the coordinator's live fence would (correctly) refuse.
            fixture.session.oversight.autoWakeTargetSessionIDs = Set(
                selectedTargetIndices.map(Self.targetID)
            )
        }
        let effectiveSelectedIndices = Set((laneIndices ?? targetIndices).filter {
            fixture.session.oversight.autoWakeOnUpdates
                || fixture.session.oversight.autoWakeTargetSessionIDs.contains(Self.targetID($0))
        })
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            Self.laneSnapshot(
                observerEndpoint: endpoint,
                linkSetRevision: linkSetRevision,
                queueRevision: queueRevision,
                targetIndices: targetIndices,
                laneIndices: laneIndices,
                edgeSequenceOffset: edgeSequenceOffset,
                metadataSequenceOffset: metadataSequenceOffset,
                overflow: overflow,
                selectedTargetIndices: effectiveSelectedIndices,
                referenceGeneration: referenceGeneration,
                queueEpoch: queueEpoch,
                latestVisibleAssistantPreview: latestVisibleAssistantPreview,
                attentionRequests: attentionRequests
            ),
            to: endpoint
        )
    }

    // MARK: - Values

    private static func targetID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0000000%d-0000-0000-0000-000000005501", index))!
    }

    private static func inventory(
        observerSessionID: UUID,
        revision: UInt64,
        targetCount: Int = 2
    ) -> AgentSessionLinkPromptInventory {
        AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: (0 ..< targetCount).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: targetID(index),
                    displayName: index == 0 ? "Build API" : "Review API",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"],
                    reference: laneReference(index)
                )
            }
        )
    }

    private static func epoch(observerSessionID: UUID) -> AgentSessionLinkPromptEpoch {
        AgentSessionLinkPromptEpoch(
            endpoint: DomainAgentSessionLinkEndpointIdentity(
                windowID: 1,
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: observerSessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: 1
            ),
            allowsSupplement: true
        )
    }

    static func laneReference(
        _ index: Int,
        generation: UInt64 = 1
    ) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(
            linkID: UUID(uuidString: String(format: "0000000F-0000-0000-0000-%012d", index + 1))!,
            generation: generation
        )
    }

    private static func laneTargetEndpoint(_ index: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(
                uuidString: String(format: "1000000%d-0000-0000-0000-000000005501", index)
            )!,
            tabID: UUID(
                uuidString: String(format: "2000000%d-0000-0000-0000-000000005501", index)
            )!,
            sessionID: targetID(index),
            persistentBindingGeneration: UUID(
                uuidString: String(format: "3000000%d-0000-0000-0000-000000005501", index)
            )!,
            bindingTransitionGeneration: 1
        )
    }

    private static let laneQueueEpoch = UUID(
        uuidString: "0000000F-0000-0000-0000-000000005501"
    )!

    private static func attentionRequest(
        _ index: Int,
        sequence: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch
    ) -> AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest {
        AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest(
            occurrence: .init(
                queueEpoch: queueEpoch,
                reference: laneReference(index),
                attentionSequence: sequence
            ),
            targetEndpoint: laneTargetEndpoint(index),
            targetSessionID: targetID(index),
            requestedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            status: .idle
        )
    }

    /// `laneIndices` defaults to the entry set, but is separable so a test can reproduce the
    /// activation publication: lanes exist and carry a target epoch while no status edge has been
    /// queued for them yet.
    private static func laneSnapshot(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        linkSetRevision: UInt64 = 1,
        queueRevision: UInt64 = 1,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        metadataSequenceOffset: UInt64 = 0,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil,
        referenceGeneration: UInt64 = 1,
        queueEpoch: UUID = laneQueueEpoch,
        latestVisibleAssistantPreview: String = "Done.",
        attentionRequests: [AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest] = []
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        let entries = targetIndices.map { index in
            AgentSessionLinkPassiveStatusNotices.PendingEntry(
                reference: laneReference(index, generation: referenceGeneration),
                targetEndpoint: laneTargetEndpoint(index),
                targetSessionID: targetID(index),
                displayName: "Build API",
                fromStatus: .running,
                toStatus: .idle,
                observedAt: Date(timeIntervalSince1970: 0),
                idleForSend: true,
                latestVisibleAssistantPreview: latestVisibleAssistantPreview,
                changeSequence: UInt64(index + 1) + edgeSequenceOffset + metadataSequenceOffset,
                edgeSequence: UInt64(index + 1) + edgeSequenceOffset
            )
        }
        return AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: queueEpoch,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: true,
            isDeliverable: true,
            entries: entries,
            attentionRequests: attentionRequests,
            unacknowledgedOverflowCount: overflow,
            overflowProduced: overflow,
            autoWakeLanes: (laneIndices ?? targetIndices).map { index in
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: laneReference(index, generation: referenceGeneration),
                    targetEndpoint: laneTargetEndpoint(index),
                    targetSessionID: targetID(index),
                    isEffectivelySelected: selectedTargetIndices?.contains(index) ?? true
                )
            }
        )
    }
}
