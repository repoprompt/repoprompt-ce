import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLinkPassiveStatusNoticeTests: XCTestCase {
    private typealias Reducer = AgentSessionLinkPassiveStatusNotices
    private typealias Status = Reducer.Status

    func testEveryLiveStatusEdgeHasTheSpecifiedDeterministicEffect() {
        struct Case {
            let from: Status
            let to: Status
            let expectedTransition: (Status, Status)?
        }

        let cases: [Case] = [
            Case(from: .idle, to: .idle, expectedTransition: nil),
            Case(from: .idle, to: .running, expectedTransition: nil),
            Case(from: .idle, to: .waiting, expectedTransition: (.idle, .waiting)),
            Case(from: .running, to: .idle, expectedTransition: (.running, .idle)),
            Case(from: .running, to: .running, expectedTransition: nil),
            Case(from: .running, to: .waiting, expectedTransition: (.running, .waiting)),
            Case(from: .waiting, to: .idle, expectedTransition: (.waiting, .idle)),
            Case(from: .waiting, to: .running, expectedTransition: nil),
            Case(from: .waiting, to: .waiting, expectedTransition: nil)
        ]

        for testCase in cases {
            var reducer = makeReducer()
            reducer.enable(samples: [sample(0, status: testCase.from)], linkSetRevision: 1)
            let baselineRevision = reducer.snapshot.queueRevision

            reducer.reconcile(
                samples: [sample(0, status: testCase.to)],
                linkSetRevision: 1,
                deliverable: true
            )

            let entries = reducer.snapshot.entries
            if let expected = testCase.expectedTransition {
                XCTAssertEqual(entries.count, 1, "\(testCase.from) -> \(testCase.to)")
                XCTAssertEqual(entries.first?.fromStatus, expected.0)
                XCTAssertEqual(entries.first?.toStatus, expected.1)
                XCTAssertGreaterThan(reducer.snapshot.queueRevision, baselineRevision)
            } else {
                XCTAssertTrue(entries.isEmpty, "\(testCase.from) -> \(testCase.to)")
                if testCase.from == testCase.to {
                    XCTAssertEqual(reducer.snapshot.queueRevision, baselineRevision)
                } else {
                    XCTAssertGreaterThan(reducer.snapshot.queueRevision, baselineRevision)
                }
            }
        }
    }

    func testEnableAndNewLinkAppearanceBaselineSilentlyAndNormalizeCapturedName() {
        var reducer = makeReducer()
        reducer.enable(
            samples: [sample(0, name: "  Build\n\tAPI  ", status: .running)],
            linkSetRevision: 1
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(
            samples: [
                sample(0, name: "ignored metadata change", status: .running),
                sample(1, status: .waiting)
            ],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty, "A newly appearing link is a baseline")

        reducer.reconcile(
            samples: [
                sample(0, name: "  Build\n\tAPI  ", status: .idle),
                sample(1, status: .waiting)
            ],
            linkSetRevision: 2,
            deliverable: true
        )
        let entry = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(entry.fromStatus, .running)
        XCTAssertEqual(entry.toStatus, .idle)
        XCTAssertFalse(entry.displayName?.contains("\n") ?? true)
        XCTAssertLessThanOrEqual(entry.displayName?.utf8.count ?? .max, 120)
    }

    /// Coalescing is first-to-final, not last-edge-wins.
    ///
    /// The delivered entry answers "what happened to this session since you last heard about it?",
    /// so the origin of the pending interval outlives every intermediate edge and the net transition
    /// is what decides whether the interval is worth reporting at all.
    func testCoalescingKeepsTheFirstToFinalEdgeAndDropsNetReversions() {
        // idle -> waiting -> idle is a round trip. There is nothing to tell the observer.
        var idleReducer = makeReducer()
        idleReducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        idleReducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        idleReducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(idleReducer.snapshot.entries.map(transition), [])

        // running -> waiting -> idle must not lose the fact that the target had been working.
        var runningReducer = makeReducer()
        runningReducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        runningReducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        runningReducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(runningReducer.snapshot.entries.map(transition), ["running->idle"])

        // idle -> waiting -> running nets to a transition that was never worth a turn.
        var runningEndReducer = makeReducer()
        runningEndReducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        runningEndReducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        runningEndReducer.reconcile(samples: [sample(0, status: .running)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(runningEndReducer.snapshot.entries.map(transition), [])
    }

    /// A same-status metadata refresh keeps the edge identity, updates the sample timestamp, and
    /// advances the sequence so a receipt rendered before the refresh can no longer clear it.
    func testSameStatusMetadataRefreshPreservesTheEdgeAndOutrunsAnOlderReceipt() {
        var reducer = makeReducer()
        let edgeObservedAt = Date(timeIntervalSince1970: 1000)
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(
            samples: [sample(0, status: .idle)],
            linkSetRevision: 1,
            deliverable: true,
            observedAt: edgeObservedAt
        )
        let claimed = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(claimed.observedAt, edgeObservedAt)
        XCTAssertFalse(claimed.idleForSend)
        let staleReceipt = AgentSessionLinkPassiveStatusNotices.Receipt(snapshot: reducer.snapshot)

        reducer.reconcile(
            samples: [sample(0, status: .idle, idleForSend: true, preview: "Done.")],
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 5000)
        )
        let refreshed = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(refreshed.fromStatus, .running)
        XCTAssertEqual(refreshed.toStatus, .idle)
        XCTAssertEqual(
            refreshed.observedAt,
            Date(timeIntervalSince1970: 5000),
            "readiness and observed_at must describe the same sampled instant"
        )
        XCTAssertTrue(refreshed.idleForSend)
        XCTAssertEqual(refreshed.latestVisibleAssistantPreview, "Done.")
        XCTAssertGreaterThan(refreshed.changeSequence, claimed.changeSequence)

        reducer.apply(staleReceipt)
        XCTAssertEqual(
            reducer.snapshot.entries.map(transition),
            ["running->idle"],
            "a receipt rendered before the refresh cannot acknowledge what it never carried"
        )
    }

    /// A sample carries only what the observer is actually shown or gated on.
    ///
    /// Target-side input provenance used to ride along here purely to feed a human-rearm fence, and a
    /// change to it produced an otherwise invisible metadata refresh: a new `changeSequence`, a fresh
    /// `observed_at`, and an acknowledged receipt invalidated, all with identical rendered content.
    /// With that fence gone the sample is rendering/readiness only, so two observations that look the
    /// same to the observer *are* the same and nothing republishes.
    func testSamplesWithIdenticalRenderedContentProduceNoMetadataRefresh() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(
            samples: [sample(0, status: .idle, idleForSend: true, preview: "Done.")],
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 1000)
        )
        let first = tryUnwrap(reducer.snapshot.entries.first)

        // Byte-identical rendered content, observed later. Nothing about the target's own input
        // history is representable any more, so there is nothing left to refresh on.
        reducer.reconcile(
            samples: [sample(0, status: .idle, idleForSend: true, preview: "Done.")],
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 9000)
        )
        let second = tryUnwrap(reducer.snapshot.entries.first)

        XCTAssertEqual(second.changeSequence, first.changeSequence)
        XCTAssertEqual(second.edgeSequence, first.edgeSequence)
        XCTAssertEqual(second.observedAt, first.observedAt)
    }

    /// Readiness is a point-in-time fact about an idle target, never an upstream assertion.
    func testReadinessIsForcedFalseUnlessTheFinalStatusIsIdle() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        reducer.reconcile(
            samples: [sample(0, status: .waiting, idleForSend: true)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertFalse(tryUnwrap(reducer.snapshot.entries.first).idleForSend)
    }

    /// Suppression is structural: metadata churn must not re-arm a wake that already failed, but a
    /// genuinely new edge must.
    func testWakeFingerprintIgnoresMetadataAndTracksStructuralChange() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let original = reducer.snapshot.wakeEligibilityFingerprint

        reducer.reconcile(
            samples: [sample(0, status: .idle, idleForSend: true, preview: "Done.")],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.wakeEligibilityFingerprint, original)

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        XCTAssertNotEqual(reducer.snapshot.wakeEligibilityFingerprint, original)
    }

    func testAcknowledgedThenRepeatedIdenticalEdgeGetsANewWakeOccurrence() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let firstSnapshot = reducer.snapshot
        let firstFingerprint = firstSnapshot.wakeEligibilityFingerprint

        reducer.apply(AgentSessionLinkPassiveStatusNotices.Receipt(snapshot: firstSnapshot))
        XCTAssertFalse(reducer.snapshot.hasDeliverableContent)
        reducer.reconcile(samples: [sample(0, status: .running)], linkSetRevision: 1, deliverable: true)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)

        XCTAssertTrue(reducer.snapshot.hasDeliverableContent)
        XCTAssertNotEqual(
            reducer.snapshot.wakeEligibilityFingerprint,
            firstFingerprint,
            "a later independent edge with the same statuses must recover from old suppression"
        )
    }

    func testEnteringRunningClearsStaleCurrentStateAndLaterCompletionIsFresh() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        let staleSequence = tryUnwrap(reducer.snapshot.entries.first).changeSequence

        reducer.reconcile(samples: [sample(0, status: .running)], linkSetRevision: 1, deliverable: true)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let completion = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(completion), "running->idle")
        XCTAssertGreaterThan(completion.changeSequence, staleSequence)
    }

    func testUnavailableRevocationAndEndpointReplacementDiscardStateAndRebaseline() {
        var reducer = makeReducer()
        reducer.enable(
            samples: [sample(0, status: .running), sample(1, status: .running)],
            linkSetRevision: 1
        )
        reducer.reconcile(
            samples: [sample(0, status: .idle), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.count, 2)

        reducer.reconcile(
            samples: [sample(0, status: .unavailable), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(\.targetSessionID), [sessionID(1)])

        reducer.reconcile(
            samples: [sample(0, status: .idle), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(\.targetSessionID), [sessionID(1)])

        reducer.reconcile(
            samples: [sample(0, status: .running, endpointGeneration: 99)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        reducer.reconcile(
            samples: [sample(0, status: .idle, endpointGeneration: 99)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(transition), ["running->idle"])
    }

    func testTemporaryNondeliverabilityContinuouslyRebaselinesAndClearsBacklog() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertFalse(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: false)
        XCTAssertTrue(reducer.snapshot.isEnabled)
        XCTAssertFalse(reducer.snapshot.isDeliverable)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: false)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.entries.map(transition), ["idle->waiting"])
    }

    func testPendingDetailsAreBoundedToTheSixteenMostRecentInDeterministicOrder() {
        var reducer = makeReducer()
        let baselines = (0 ..< 18).map { sample($0, status: .running) }
        reducer.enable(samples: baselines.reversed(), linkSetRevision: 1)
        reducer.reconcile(
            samples: (0 ..< 18).reversed().map { sample($0, status: .idle) },
            linkSetRevision: 1,
            deliverable: true
        )

        let snapshot = reducer.snapshot
        XCTAssertEqual(snapshot.entries.count, 16)
        XCTAssertEqual(snapshot.entries.map(\.targetSessionID), (2 ..< 18).map(sessionID))
        XCTAssertEqual(snapshot.entries.map(\.changeSequence), Array(3 ... 18).map(UInt64.init))
        XCTAssertEqual(reducer.overflowProduced, 2)
        XCTAssertEqual(reducer.overflowAcknowledged, 0)
        XCTAssertEqual(snapshot.unacknowledgedOverflowCount, 2)
        XCTAssertEqual(snapshot.overflowProduced, 2)
    }

    /// Overflow acknowledgement is a watermark, and a watermark has to be absolute.
    ///
    /// The displayed omitted count is a remainder: it shrinks as receipts land. A receipt echoing it
    /// would acknowledge only the newest cycle's shortfall, so every further cycle would strand more
    /// overflow and the envelope would keep reporting dropped changes that were already accounted for.
    /// Three cycles, because one is exactly the case a delta and a watermark agree on.
    func testRepeatedOverflowCyclesAreFullyAcknowledgedBySuccessiveReceipts() {
        var reducer = makeReducer()
        reducer.enable(samples: (0 ..< 18).map { sample($0, status: .running) }, linkSetRevision: 1)

        // Each pass moves all 18 targets across an actionable edge, so two of them always overflow
        // the sixteen-entry bound.
        for (cycle, status) in [Status.idle, .waiting, .idle].enumerated() {
            reducer.reconcile(
                samples: (0 ..< 18).map { sample($0, status: status) },
                linkSetRevision: 1,
                deliverable: true
            )
            let expectedProduced = UInt64((cycle + 1) * 2)
            let claimed = reducer.snapshot
            XCTAssertEqual(claimed.entries.count, 16, "cycle \(cycle)")
            XCTAssertEqual(claimed.overflowProduced, expectedProduced, "cycle \(cycle)")
            XCTAssertEqual(claimed.unacknowledgedOverflowCount, 2, "cycle \(cycle)")

            reducer.apply(Reducer.Receipt(snapshot: claimed))

            XCTAssertEqual(reducer.overflowAcknowledged, expectedProduced, "cycle \(cycle)")
            XCTAssertEqual(
                reducer.snapshot.unacknowledgedOverflowCount,
                0,
                "cycle \(cycle) left overflow permanently unacknowledgeable"
            )
            XCTAssertTrue(reducer.snapshot.entries.isEmpty, "cycle \(cycle)")
            XCTAssertFalse(reducer.snapshot.hasDeliverableContent, "cycle \(cycle)")
        }
    }

    /// Overflow with no surviving entry is still worth saying, and still has to be acknowledgeable.
    ///
    /// Reached whenever the queue drops changes and then loses every pending entry — here because all
    /// overseen targets stop being observable at once. Gating delivery on a nonempty entry list would
    /// leave the count owed for as long as the observer happened to see no further change.
    func testOverflowSurvivesLosingEveryEntryAndIsDeliverableOnItsOwn() {
        var reducer = overflowReducer()
        reducer.reconcile(
            samples: (0 ..< 18).map { sample($0, status: .unavailable) },
            linkSetRevision: 1,
            deliverable: true
        )

        let claimed = reducer.snapshot
        XCTAssertTrue(claimed.entries.isEmpty)
        XCTAssertEqual(claimed.unacknowledgedOverflowCount, 2)
        XCTAssertEqual(claimed.overflowProduced, 2)
        XCTAssertTrue(
            claimed.hasDeliverableContent,
            "an overflow-only snapshot is the only account the agent gets of what it missed"
        )

        reducer.apply(Reducer.Receipt(snapshot: claimed))

        XCTAssertEqual(reducer.overflowAcknowledged, 2)
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 0)
        XCTAssertFalse(
            reducer.snapshot.hasDeliverableContent,
            "an acknowledged overflow-only batch must not be owed again"
        )
    }

    /// Auto-wake membership rides the reducer, so the snapshot a receipt produces carries it too.
    ///
    /// Every published snapshot is an input to the Auto-wake acceptance fence. A receipt that
    /// republished a lane-less snapshot would read to the fence as "no lane is selected any more",
    /// retracting a live attempt.
    func testAutoWakeLanesSurviveReceiptRepublicationAndAreReplacedWholesale() {
        var reducer = overflowReducer()
        let lanes = (0 ..< 2).map { index in
            Reducer.AutoWakeLane(
                reference: DomainAgentSessionLinkReference(
                    linkID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
                    generation: 1
                ),
                targetEndpoint: endpoint(sessionID: sessionID(index), generation: 1),
                targetSessionID: sessionID(index),
                isEffectivelySelected: index == 0
            )
        }
        reducer.setAutoWakeLanes(lanes)
        let claimed = reducer.snapshot
        XCTAssertEqual(claimed.autoWakeLanes, lanes)
        XCTAssertEqual(
            Set(claimed.effectivelySelectedAutoWakeLanesByReference.keys),
            [lanes[0].reference]
        )

        reducer.apply(Reducer.Receipt(
            snapshot: claimed,
            deliveredEntries: Array(claimed.entries.prefix(2)),
            overflowProducedThrough: 1
        ))
        XCTAssertEqual(reducer.snapshot.autoWakeLanes, lanes)

        reducer.setAutoWakeLanes([])
        XCTAssertTrue(reducer.snapshot.autoWakeLanes.isEmpty)
    }

    func testReceiptAcknowledgesOnlyDeliveredEntriesAndRenderedOverflow() {
        var reducer = overflowReducer()
        let claimed = reducer.snapshot
        let delivered = Array(claimed.entries.prefix(2))
        reducer.apply(Reducer.Receipt(
            snapshot: claimed,
            deliveredEntries: delivered,
            overflowProducedThrough: 1
        ))

        XCTAssertEqual(reducer.snapshot.entries.count, 14)
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 1)
        XCTAssertEqual(reducer.snapshot.overflowProduced, 2)
        XCTAssertEqual(reducer.overflowAcknowledged, 1)
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, claimed.queueRevision)
        XCTAssertGreaterThan(reducer.snapshot.queueRevision, claimed.queueRevision)
    }

    func testInFlightReceiptPreservesNewerStatusAndOverflowProducedAfterClaim() {
        var reducer = overflowReducer()
        let claimed = reducer.snapshot
        let deliveredEntry = tryUnwrap(claimed.entries.first)

        var current = (0 ..< 18).map { sample($0, status: .idle) }
        current[0] = sample(0, status: .waiting)
        current[2] = sample(2, status: .running)
        reducer.reconcile(samples: current, linkSetRevision: 1, deliverable: true)
        current[2] = sample(2, status: .idle)
        reducer.reconcile(samples: current, linkSetRevision: 1, deliverable: true)
        XCTAssertGreaterThan(reducer.overflowProduced, claimed.unacknowledgedOverflowCount)

        reducer.apply(Reducer.Receipt(
            snapshot: claimed,
            deliveredEntries: [deliveredEntry],
            overflowProducedThrough: claimed.overflowProduced
        ))

        let currentEntry = tryUnwrap(reducer.snapshot.entries.first { $0.reference == deliveredEntry.reference })
        XCTAssertGreaterThan(currentEntry.changeSequence, deliveredEntry.changeSequence)
        XCTAssertEqual(transition(currentEntry), "running->idle")
        XCTAssertGreaterThan(reducer.snapshot.unacknowledgedOverflowCount, 0)
    }

    func testDuplicateAndOutOfOrderReceiptsAreMonotonicAndIdempotent() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let revisionOne = reducer.snapshot

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        let revisionTwo = reducer.snapshot
        let receiptTwo = Reducer.Receipt(snapshot: revisionTwo)
        reducer.apply(receiptTwo)
        let afterNewestReceipt = reducer.snapshot
        XCTAssertTrue(afterNewestReceipt.entries.isEmpty)

        reducer.apply(Reducer.Receipt(snapshot: revisionOne))
        reducer.apply(receiptTwo)
        XCTAssertEqual(reducer.snapshot, afterNewestReceipt)
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, revisionTwo.queueRevision)
    }

    func testAttentionAtCapacityRefusesAtEnqueueAndNeverEvictsOrOverflows() {
        var reducer = makeReducer()
        reducer.enable(
            samples: (0 ... Reducer.maximumPendingAttentionRequestCount)
                .map { sample($0, status: .idle) },
            linkSetRevision: 1
        )

        for index in 0 ..< Reducer.maximumPendingAttentionRequestCount {
            XCTAssertEqual(
                requestAttention(index, reducer: &reducer, requestedAt: Date(timeIntervalSince1970: Double(index))),
                .accepted
            )
        }
        let fullSnapshot = reducer.snapshot

        XCTAssertEqual(
            requestAttention(0, reducer: &reducer, requestedAt: Date(timeIntervalSince1970: 9000)),
            .accepted,
            "a duplicate must reveal no pending-versus-new state"
        )
        XCTAssertEqual(
            reducer.snapshot,
            fullSnapshot,
            "a duplicate must not change ordering, timestamps, revision, or fingerprint"
        )
        XCTAssertEqual(
            requestAttention(
                Reducer.maximumPendingAttentionRequestCount,
                reducer: &reducer,
                requestedAt: Date(timeIntervalSince1970: 10000)
            ),
            .atCapacity
        )
        XCTAssertEqual(reducer.snapshot.attentionRequests.count, Reducer.maximumPendingAttentionRequestCount)
        XCTAssertEqual(reducer.snapshot.attentionRequests.first?.targetSessionID, sessionID(0))
        XCTAssertEqual(reducer.snapshot.attentionRequests.last?.targetSessionID, sessionID(15))
        XCTAssertEqual(reducer.overflowProduced, 0, "refused attention never enters status overflow")
        XCTAssertEqual(reducer.overflowAcknowledged, 0)
    }

    func testStatusOverflowNeverConsumesOrAttributesAttention() {
        var reducer = makeReducer()
        reducer.enable(
            samples: (0 ..< 18).map { sample($0, status: .running) },
            linkSetRevision: 1
        )
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        let occurrence = tryUnwrap(reducer.snapshot.attentionRequests.first).occurrence

        reducer.reconcile(
            samples: (0 ..< 18).map { sample($0, status: .idle) },
            linkSetRevision: 1,
            deliverable: true
        )

        XCTAssertEqual(reducer.snapshot.entries.count, Reducer.maximumPendingTargetCount)
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 2)
        XCTAssertEqual(reducer.snapshot.attentionRequests.map(\.occurrence), [occurrence])
    }

    func testAttentionSurvivesStatusChurnAndIsClearedByLifecycleInvalidation() {
        var reducer = makeReducer()
        reducer.enable(
            samples: [sample(0, status: .running), sample(1, status: .running)],
            linkSetRevision: 1
        )
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        XCTAssertEqual(requestAttention(1, reducer: &reducer), .accepted)

        reducer.reconcile(
            samples: [sample(0, status: .idle), sample(1, status: .waiting)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(
            Set(reducer.snapshot.attentionRequests.map(\.targetSessionID)),
            [sessionID(0), sessionID(1)]
        )

        reducer.reconcile(
            samples: [sample(1, status: .waiting)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.attentionRequests.map(\.targetSessionID), [sessionID(1)])

        reducer.reconcile(
            samples: [sample(1, status: .unavailable)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertTrue(reducer.snapshot.attentionRequests.isEmpty)

        reducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 3)
        XCTAssertEqual(requestAttention(0, reducer: &reducer, linkSetRevision: 3), .accepted)
        reducer.disable(linkSetRevision: 3)
        XCTAssertTrue(reducer.snapshot.attentionRequests.isEmpty)
    }

    func testStaleReceiptDoesNotClearSuccessorAttentionOccurrence() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        let firstSnapshot = reducer.snapshot
        let firstOccurrence = tryUnwrap(firstSnapshot.attentionRequests.first).occurrence

        reducer.apply(Reducer.Receipt(snapshot: firstSnapshot))
        XCTAssertTrue(reducer.snapshot.attentionRequests.isEmpty)
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        let successorOccurrence = tryUnwrap(reducer.snapshot.attentionRequests.first).occurrence
        XCTAssertNotEqual(successorOccurrence, firstOccurrence)

        reducer.apply(Reducer.Receipt(snapshot: firstSnapshot))
        XCTAssertEqual(reducer.snapshot.attentionRequests.map(\.occurrence), [successorOccurrence])
    }

    func testAttentionReceiptAppliesIndependentlyOfGlobalQueueRevisionGate() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        let olderAttentionClaim = reducer.snapshot

        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let newerStatusClaim = reducer.snapshot
        reducer.apply(Reducer.Receipt(
            snapshot: newerStatusClaim,
            deliveredAttentionRequests: []
        ))
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, newerStatusClaim.queueRevision)
        XCTAssertEqual(reducer.snapshot.attentionRequests.count, 1)

        reducer.apply(Reducer.Receipt(snapshot: olderAttentionClaim))
        XCTAssertTrue(
            reducer.snapshot.attentionRequests.isEmpty,
            "an older claim that rendered the exact occurrence must still settle it"
        )
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, newerStatusClaim.queueRevision)
    }

    func testStandaloneAttentionRefreshesMetadataWithoutNewOccurrenceOrFingerprint() throws {
        var reducer = makeReducer()
        let baselineObservedAt = Date(timeIntervalSince1970: 900)
        let initialWaitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: "Initial dependency",
            declaredAt: Date(timeIntervalSince1970: 800)
        ))
        reducer.enable(
            samples: [sample(
                0,
                name: "Initial target",
                status: .idle,
                waitingOn: initialWaitingOn,
                preview: "Still working."
            )],
            linkSetRevision: 1,
            observedAt: baselineObservedAt
        )
        let requestedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(requestAttention(0, reducer: &reducer, requestedAt: requestedAt), .accepted)
        let originalSnapshot = reducer.snapshot
        let original = try XCTUnwrap(originalSnapshot.attentionRequests.first)
        XCTAssertEqual(original.displayName, "Initial target")
        XCTAssertEqual(original.observedAt, baselineObservedAt)
        XCTAssertEqual(original.waitingOn, initialWaitingOn)
        XCTAssertEqual(original.latestVisibleAssistantPreview, "Still working.")
        XCTAssertNotEqual(
            original.observedAt,
            original.requestedAt,
            "the request timestamp must not be relabeled as the older status observation time"
        )
        let waitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: "Review the final build",
            declaredAt: Date(timeIntervalSince1970: 1500)
        ))

        reducer.reconcile(
            samples: [sample(
                0,
                name: "Current target",
                status: .idle,
                idleForSend: true,
                waitingOn: waitingOn,
                preview: "Build is ready."
            )],
            linkSetRevision: 1,
            deliverable: true,
            observedAt: Date(timeIntervalSince1970: 2000)
        )

        let refreshedSnapshot = reducer.snapshot
        let refreshed = try XCTUnwrap(refreshedSnapshot.attentionRequests.first)
        XCTAssertEqual(refreshed.occurrence, original.occurrence)
        XCTAssertEqual(refreshed.requestedAt, requestedAt)
        XCTAssertEqual(refreshed.displayName, "Current target")
        XCTAssertEqual(refreshed.status, .idle)
        XCTAssertTrue(refreshed.idleForSend)
        XCTAssertEqual(refreshed.waitingOn, waitingOn)
        XCTAssertEqual(refreshed.latestVisibleAssistantPreview, "Build is ready.")
        XCTAssertEqual(refreshed.observedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(
            refreshedSnapshot.wakeEligibilityFingerprint,
            originalSnapshot.wakeEligibilityFingerprint,
            "presentation-only refresh must not create a fresh attention occurrence"
        )
        XCTAssertGreaterThan(refreshedSnapshot.queueRevision, originalSnapshot.queueRevision)
    }

    func testOldEpochReceiptDisableAndLastLinkRemovalCannotResurrectQueueState() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let claimed = reducer.snapshot

        try reducer.apply(Reducer.Receipt(
            queueEpoch: XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
            queueRevision: claimed.queueRevision,
            deliveredStatuses: claimed.entries.map(Reducer.DeliveredStatus.init),
            overflowProducedThrough: 0
        ))
        XCTAssertEqual(reducer.snapshot.entries.count, 1)

        reducer.disable(linkSetRevision: 1)
        XCTAssertFalse(reducer.snapshot.isEnabled)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        reducer.apply(Reducer.Receipt(snapshot: claimed))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 2)
        reducer.reconcile(samples: [], linkSetRevision: 3, deliverable: true)
        XCTAssertFalse(reducer.snapshot.isEnabled)
        XCTAssertFalse(reducer.snapshot.isDeliverable)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertEqual(reducer.snapshot.linkSetRevision, 3)
    }

    // MARK: - Fixtures

    private func makeReducer() -> Reducer {
        Reducer(
            observerEndpoint: endpoint(sessionID: observerSessionID, generation: 1),
            queueEpoch: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
    }

    private func overflowReducer() -> Reducer {
        var reducer = makeReducer()
        reducer.enable(
            samples: (0 ..< 18).map { sample($0, status: .running) },
            linkSetRevision: 1
        )
        reducer.reconcile(
            samples: (0 ..< 18).map { sample($0, status: .idle) },
            linkSetRevision: 1,
            deliverable: true
        )
        return reducer
    }

    @discardableResult
    private func requestAttention(
        _ index: Int,
        reducer: inout Reducer,
        linkSetRevision: UInt64 = 1,
        requestedAt: Date = Date()
    ) -> Reducer.AttentionRequestResult {
        let target = sample(index, status: .idle)
        return reducer.requestAttention(
            reference: target.reference,
            targetEndpoint: target.targetEndpoint,
            targetSessionID: target.targetSessionID,
            linkSetRevision: linkSetRevision,
            requestedAt: requestedAt
        )
    }

    private func sample(
        _ index: Int,
        name: String? = nil,
        status: Status,
        endpointGeneration: UInt64 = 1,
        idleForSend: Bool = false,
        waitingOn: DomainAgentSessionWaitingOn? = nil,
        preview: String? = nil
    ) -> Reducer.Sample {
        let targetSessionID = sessionID(index)
        return Reducer.Sample(
            reference: DomainAgentSessionLinkReference(
                linkID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
                generation: 1
            ),
            targetEndpoint: endpoint(sessionID: targetSessionID, generation: endpointGeneration),
            targetSessionID: targetSessionID,
            displayName: name ?? "Target \(index)",
            status: status,
            idleForSend: idleForSend,
            waitingOn: waitingOn,
            latestVisibleAssistantPreview: preview
        )
    }

    private func endpoint(
        sessionID: UUID,
        generation: UInt64
    ) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: Int(generation),
            workspaceID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            tabID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sessionID: sessionID,
            persistentBindingGeneration: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
            bindingTransitionGeneration: generation
        )
    }

    private var observerSessionID: UUID {
        UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    }

    private func sessionID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func transition(_ entry: Reducer.PendingEntry) -> String {
        "\(entry.fromStatus.rawValue)->\(entry.toStatus.rawValue)"
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
