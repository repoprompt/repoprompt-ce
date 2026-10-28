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

    func testPartialStatusReceiptsSettleAfterEqualOrNewerReceipt() {
        for newer in [false, true] {
            var reducer = overflowReducer()
            let old = reducer.snapshot
            let delivered = Array(old.entries.prefix(2))
            if newer {
                XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
            }
            let later = reducer.snapshot
            reducer.apply(Reducer.Receipt(
                snapshot: later, deliveredEntries: [],
                deliveredAttentionRequests: later.attentionRequests,
                overflowProducedThrough: later.overflowProduced
            ))
            let before = reducer.snapshot.queueRevision
            let receipt = Reducer.Receipt(snapshot: old, deliveredEntries: delivered, overflowProducedThrough: 0)
            reducer.apply(receipt)
            XCTAssertTrue(reducer.snapshot.entries.allSatisfy { entry in
                !delivered.contains { $0.reference == entry.reference }
            })
            XCTAssertGreaterThan(reducer.snapshot.queueRevision, before)
            XCTAssertEqual(reducer.lastAcceptedReceiptRevision, later.queueRevision)
            XCTAssertEqual(reducer.overflowAcknowledged, later.overflowProduced)
            let settled = reducer.snapshot
            reducer.apply(receipt)
            XCTAssertEqual(reducer.snapshot, settled)
        }
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
        preview: String? = nil,
        runFacts: AgentRunQuietFacts? = nil
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
            latestVisibleAssistantPreview: preview,
            runFacts: runFacts
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

extension AgentSessionLinkPassiveStatusNoticeTests {
    private func facts(_ settled: UInt64, _ ordinary: UInt64) -> AgentRunQuietFacts {
        AgentRunQuietFacts(settledThrough: settled, ordinaryThrough: ordinary)!
    }

    private func observe(_ reducer: inout Reducer, _ status: Status, _ proof: AgentRunQuietFacts?, index: Int = 0) {
        reducer.reconcile(samples: [sample(index, status: status, runFacts: proof)], linkSetRevision: 1, deliverable: true)
    }

    func testF7r1DroppedOrdinaryThenQuietSamplesCreateTruthfulIdleCoverageOnce() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(10, 9))
        let entry = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(entry), "idle->idle")
        XCTAssertTrue(entry.isRoutineWakeEligible)
        XCTAssertEqual(entry.ordinaryThrough, 9)
        XCTAssertEqual(reducer.deliveredRunThrough(for: entry.reference), 8)
        let fingerprint = reducer.snapshot.wakeEligibilityFingerprint
        observe(&reducer, .idle, facts(11, 9))
        XCTAssertEqual(reducer.snapshot.wakeEligibilityFingerprint, fingerprint, "quiet settlement changes cutoff, not failed occurrence")
        let receipt = Reducer.Receipt(snapshot: reducer.snapshot)
        reducer.apply(receipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: entry.reference), 11)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        observe(&reducer, .idle, facts(12, 9))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
    }

    func testF5ReceiptNinePaysBeforeRunningCleanupAndCannotPayOrdinaryTen() throws {
        for ordinarySuccessor in [false, true] {
            var reducer = makeReducer()
            reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
            observe(&reducer, .idle, facts(9, 9))
            let receipt = Reducer.Receipt(snapshot: reducer.snapshot)
            let reference = try XCTUnwrap(reducer.snapshot.entries.first?.reference)
            observe(&reducer, .running, facts(9, 9))
            XCTAssertEqual(reducer.snapshot.entries.first?.toStatus, .running)
            reducer.apply(receipt)
            XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 9)
            XCTAssertTrue(reducer.snapshot.entries.isEmpty, "paid coverage-only running row retires independently of status guard")
            observe(&reducer, .idle, facts(10, ordinarySuccessor ? 10 : 9))
            XCTAssertEqual(reducer.snapshot.entries.count, ordinarySuccessor ? 1 : 0)
            if ordinarySuccessor {
                reducer.apply(receipt)
                XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 10)
                XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 9)
            }
        }
    }

    func testQuietIntervalPreservesFailedIdentityButUnpairedCloseAdvancesItAcrossBothOrigins() throws {
        for origin in [Status.idle, .running] {
            for paired in [false, true] {
                var reducer = makeReducer()
                reducer.enable(samples: [sample(0, status: origin, runFacts: facts(8, 8))], linkSetRevision: 1)
                observe(&reducer, .idle, facts(9, 9))
                let fingerprint = reducer.snapshot.wakeEligibilityFingerprint
                let oldEdge = try XCTUnwrap(reducer.snapshot.entries.first?.edgeSequence)
                observe(&reducer, .running, facts(9, 9))
                observe(&reducer, .idle, paired ? facts(10, 9) : nil)
                let entry = try XCTUnwrap(reducer.snapshot.entries.first)
                XCTAssertEqual(entry.fromStatus, origin)
                XCTAssertEqual(entry.edgeSequence == oldEdge, paired)
                XCTAssertEqual(reducer.snapshot.wakeEligibilityFingerprint == fingerprint, paired)
                XCTAssertEqual(entry.isRoutineWakeEligible, paired || origin == .running)
                if !paired {
                    let unknownReceipt = Reducer.Receipt(snapshot: reducer.snapshot)
                    reducer.apply(unknownReceipt)
                    XCTAssertEqual(reducer.deliveredRunThrough(for: entry.reference), 8)
                    XCTAssertFalse(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
                    for _ in 0 ..< 5 {
                        observe(&reducer, .idle, nil)
                    }
                    XCTAssertFalse(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
                    observe(&reducer, .idle, facts(10, 9))
                    XCTAssertTrue(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
                    reducer.apply(.init(snapshot: reducer.snapshot))
                    XCTAssertEqual(reducer.deliveredRunThrough(for: entry.reference), 10)
                    XCTAssertTrue(reducer.snapshot.entries.isEmpty)
                }
            }
        }
    }

    func testUnavailableAndUnpairedRunningResumeRecoverFirstFreshIdleWithoutRebaseline() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        let reference = sample(0, status: .idle).reference
        observe(&reducer, .idle, facts(9, 9))
        observe(&reducer, .unavailable, nil)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)
        observe(&reducer, .running, nil)
        observe(&reducer, .idle, nil)
        reducer.apply(.init(snapshot: reducer.snapshot))
        observe(&reducer, .idle, facts(10, 9))
        XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 9)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 10)
        for _ in 0 ..< 5 {
            observe(&reducer, .idle, facts(10, 9))
        }
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
    }

    func testUnknownOnlyAcceptedStatusClearsWithoutInventingDeliveredPosition() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        observe(&reducer, .idle, nil)
        let reference = try XCTUnwrap(reducer.snapshot.entries.first?.reference)
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertNil(reducer.deliveredRunThrough(for: reference))
    }

    func testUnpairedWaitingAcceptanceRetainsInertCoverageAndNextRealWaitingEdge() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(9, 9))
        observe(&reducer, .waiting, nil)
        let receipt = Reducer.Receipt(snapshot: reducer.snapshot)
        let reference = try XCTUnwrap(reducer.snapshot.entries.first?.reference)
        reducer.apply(receipt)
        let settled = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(settled), "waiting->waiting")
        XCTAssertFalse(settled.isRoutineWakeEligible)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)
        for _ in 0 ..< 5 {
            observe(&reducer, .waiting, facts(9, 9))
        }
        XCTAssertFalse(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
        let failed = reducer.snapshot.wakeEligibilityFingerprint
        observe(&reducer, .running, facts(9, 9))
        observe(&reducer, .waiting, facts(9, 9))
        let fresh = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(fresh), "running->waiting")
        XCTAssertTrue(fresh.isRoutineWakeEligible)
        XCTAssertNotEqual(reducer.snapshot.wakeEligibilityFingerprint, failed)
        reducer.apply(receipt)
        XCTAssertEqual(reducer.snapshot.entries.first, fresh, "old receipt cannot demote the new actionable edge")
        observe(&reducer, .idle, facts(10, 10))
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 10)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
    }

    func testSameStatusUnpairedRefreshPaysOnlyItsFrozenOlderCutoff() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(9, 9))
        reducer.reconcile(samples: [sample(0, status: .idle, preview: "new metadata")], linkSetRevision: 1, deliverable: true)
        let entry = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertNil(entry.runFacts, "older cutoff is payment, never current fresh admission proof")
        XCTAssertEqual(entry.receiptSettledThrough, 9)
        XCTAssertFalse(entry.isRoutineWakeEligible)
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertEqual(reducer.deliveredRunThrough(for: entry.reference), 9)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
    }

    func testRegressingPairCannotSupplyFreshProofOrReplaceCachedCoverage() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(10, 9))
        observe(&reducer, .running, nil)
        observe(&reducer, .idle, facts(9, 8))
        let entry = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertNil(entry.runFacts)
        XCTAssertEqual(entry.ordinaryThrough, 9)
        XCTAssertFalse(entry.isRoutineWakeEligible)
        observe(&reducer, .idle, facts(11, 10))
        XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 10)
        XCTAssertTrue(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
    }

    func testEvictionDoesNotPayAndAnonymousOverflowCannotPayTargets() {
        var reducer = makeReducer()
        let baseline = (0 ..< 18).map { sample($0, status: .idle, runFacts: facts(8, 8)) }
        reducer.enable(samples: baseline, linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle, runFacts: facts(9, 9))] + Array(baseline.dropFirst()), linkSetRevision: 1, deliverable: true)
        let oldReceipt = Reducer.Receipt(snapshot: reducer.snapshot)
        let newSamples = (0 ..< 18).map { sample($0, status: .idle, runFacts: facts(9, 9)) }
        reducer.reconcile(samples: newSamples, linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.entries.count, 16)
        XCTAssertEqual(reducer.snapshot.overflowProduced, 2)
        let reference = sample(0, status: .idle).reference
        XCTAssertFalse(reducer.snapshot.entries.contains { $0.reference == reference })
        let overflowReceipt = Reducer.Receipt(snapshot: reducer.snapshot, deliveredEntries: [])
        reducer.apply(overflowReceipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)
        reducer.apply(oldReceipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 9, "rendered payment precedes missing-row guard")
        let produced = reducer.snapshot.overflowProduced
        for _ in 0 ..< 5 {
            reducer.reconcile(samples: newSamples, linkSetRevision: 1, deliverable: true)
        }
        XCTAssertEqual(reducer.snapshot.overflowProduced, produced)
        var newer = newSamples
        newer[0] = sample(0, status: .idle, runFacts: facts(10, 10))
        reducer.reconcile(samples: newer, linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.overflowProduced, produced + 1)
        XCTAssertEqual(reducer.snapshot.entries.count, 16)
    }

    func testFirstPairedFactsAtSettlementBaselineSilentlyWhilePairedRestingBaselineOwesTheRun() throws {
        // Unpaired seed: the first paired facts arrive already settled, so they are the baseline.
        var unpaired = makeReducer()
        unpaired.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        observe(&unpaired, .idle, facts(1, 1))
        XCTAssertTrue(unpaired.snapshot.entries.isEmpty, "unknown is never zero; first paired facts baseline")
        XCTAssertEqual(unpaired.deliveredRunThrough(for: sample(0, status: .idle).reference), 1)

        // A paired resting baseline makes the same settled ordinary run owed and routine-eligible.
        var paired = makeReducer()
        paired.enable(samples: [sample(0, status: .idle, runFacts: facts(0, 0))], linkSetRevision: 1)
        observe(&paired, .idle, facts(1, 1))
        let owed = try XCTUnwrap(paired.snapshot.entries.first)
        XCTAssertEqual(owed.ordinaryThrough, 1)
        XCTAssertTrue(owed.isRoutineWakeEligible)
    }

    func testMissedOrdinaryRunCoalescesALaterRealCompletionFirstToFinal() throws {
        // Missed running frame: the settled ordinary run is idle -> idle coverage, and a later real
        // running -> idle keeps that first-to-final origin while still admitting.
        var missed = makeReducer()
        missed.enable(samples: [sample(0, status: .idle, runFacts: facts(0, 0))], linkSetRevision: 1)
        observe(&missed, .idle, facts(1, 1))
        observe(&missed, .running, facts(1, 1))
        observe(&missed, .idle, facts(1, 1))
        let coalesced = try XCTUnwrap(missed.snapshot.entries.first)
        XCTAssertEqual(transition(coalesced), "idle->idle")
        XCTAssertTrue(coalesced.isRoutineWakeEligible)

        // Observed running frame: the same ordinary run is a running -> idle completion edge.
        var observed = makeReducer()
        observed.enable(samples: [sample(0, status: .idle, runFacts: facts(0, 0))], linkSetRevision: 1)
        observe(&observed, .running, facts(0, 0))
        observe(&observed, .idle, facts(1, 1))
        let edge = try XCTUnwrap(observed.snapshot.entries.first)
        XCTAssertEqual(transition(edge), "running->idle")
        XCTAssertTrue(edge.isRoutineWakeEligible)
    }

    func testQuietCyclesDoNotReRepresentOverflowedOrdinaryCoverageOrRearmFailedWake() {
        var reducer = makeReducer()
        let lanes = 0 ..< 18
        func all(_ status: Status, _ proof: AgentRunQuietFacts) -> [Reducer.Sample] {
            lanes.map { sample($0, status: status, runFacts: proof) }
        }
        reducer.enable(samples: all(.idle, facts(8, 8)), linkSetRevision: 1)
        // Lane 0 is rendered first, so its row is the oldest and is evicted below.
        reducer.reconcile(
            samples: [sample(0, status: .idle, runFacts: facts(9, 9))] + Array(all(.idle, facts(8, 8)).dropFirst()),
            linkSetRevision: 1,
            deliverable: true
        )
        let lateReceipt = Reducer.Receipt(snapshot: reducer.snapshot)
        reducer.reconcile(samples: all(.idle, facts(9, 9)), linkSetRevision: 1, deliverable: true)
        let evicted = sample(0, status: .idle).reference
        XCTAssertEqual(reducer.snapshot.entries.count, 16)
        XCTAssertEqual(reducer.snapshot.overflowProduced, 2)
        XCTAssertFalse(reducer.snapshot.entries.contains { $0.reference == evicted })
        let failedIdentity = reducer.snapshot.wakeEligibilityFingerprint

        // Receipts withheld; every cycle is a quiet running -> idle settlement with no new ordinary
        // watermark. Debt already disclosed as anonymous overflow is not a fresh occurrence.
        var settled: UInt64 = 9
        for cycle in 1 ... 4 {
            reducer.reconcile(samples: all(.running, facts(settled, 9)), linkSetRevision: 1, deliverable: true)
            settled += 1
            reducer.reconcile(samples: all(.idle, facts(settled, 9)), linkSetRevision: 1, deliverable: true)
            XCTAssertEqual(reducer.snapshot.overflowProduced, 2, "quiet cycle \(cycle) must not manufacture overflow")
            XCTAssertEqual(reducer.snapshot.entries.count, 16)
            XCTAssertFalse(reducer.snapshot.entries.contains { $0.reference == evicted })
            XCTAssertEqual(
                reducer.snapshot.wakeEligibilityFingerprint,
                failedIdentity,
                "quiet cycle \(cycle) must not re-arm the failed wake identity"
            )
        }
        XCTAssertEqual(reducer.deliveredRunThrough(for: evicted), 8, "eviction and quiet churn never pay")

        // The late exact receipt still pays its frozen cutoff for the evicted lane.
        reducer.apply(lateReceipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: evicted), 9)

        // A genuinely new ordinary watermark is a new occurrence and may overflow again.
        let newer = [sample(0, status: .idle, runFacts: facts(settled + 1, 10))] + Array(all(.idle, facts(settled, 9)).dropFirst())
        reducer.reconcile(samples: newer, linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.overflowProduced, 3)
        XCTAssertTrue(reducer.snapshot.entries.contains { $0.reference == evicted })
        XCTAssertNotEqual(reducer.snapshot.wakeEligibilityFingerprint, failedIdentity)
    }

    func testQuietSuccessorCloseRepresentsOrdinaryFirstSampledWhileRunningAndPaysFrozenReceipt() throws {
        var reducer = makeReducer()
        let reference = sample(0, status: .idle).reference
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        // The ordinary close at 9 was missed; its first sample is the successor's running frame.
        observe(&reducer, .running, facts(9, 9))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)

        // Quiet successor 10 cannot suppress the still-unrepresented ordinary settlement 9.
        observe(&reducer, .idle, facts(10, 9))
        XCTAssertEqual(reducer.snapshot.entries.count, 1, "unpaid ordinary 9 must be represented at the quiet close")
        XCTAssertEqual(reducer.snapshot.entries.first?.toStatus, .idle)
        XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 9)
        XCTAssertEqual(reducer.snapshot.entries.first?.receiptSettledThrough, 10)
        XCTAssertEqual(reducer.snapshot.entries.first?.isRoutineWakeEligible, true, "ordinary 9 must independently admit")
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8, "representation is not payment")
        let entry = try XCTUnwrap(reducer.snapshot.entries.first)
        let receipt = Reducer.Receipt(snapshot: reducer.snapshot)

        // Unchanged idle cannot churn the row; later quiet facts cannot enlarge this receipt.
        observe(&reducer, .idle, facts(10, 9))
        XCTAssertEqual(reducer.snapshot.entries.first, entry)
        observe(&reducer, .idle, facts(11, 9))
        reducer.apply(receipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 10, "acceptance pays only frozen settled cutoff 10")
        XCTAssertFalse(reducer.snapshot.entries.contains(where: \.isRoutineWakeEligible))
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 11)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        observe(&reducer, .idle, facts(12, 9))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty, "paid ordinary coverage cannot echo on quiet settlement")
    }

    func testOrdinaryFirstSampledWhileRunningStillRepresentsAtIdle() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .running, facts(9, 9))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        observe(&reducer, .idle, facts(9, 9))
        XCTAssertEqual(reducer.snapshot.entries.first?.ordinaryThrough, 9)
        XCTAssertTrue(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
    }
}

extension AgentSessionLinkPassiveStatusNoticeTests {
    func testBothPristineWaitingCyclesStayDistinctWithAndWithoutRetainedCoverage() throws {
        for coverage in [false, true] {
            for intermediate in [Status.running, .idle] {
                var reducer = makeReducer()
                reducer.enable(samples: [sample(0, status: .waiting, runFacts: coverage ? facts(8, 8) : nil)], linkSetRevision: 1)
                if coverage {
                    observe(&reducer, .idle, facts(9, 9))
                    observe(&reducer, .waiting, facts(9, 9))
                    // This is pristine actionable waiting→idle→waiting net reversion, retaining
                    // only unpaid coverage, not inventing a waiting edge.
                    XCTAssertFalse(try XCTUnwrap(reducer.snapshot.entries.first).isStatusEdge)
                }
                observe(&reducer, intermediate, coverage ? facts(9, 9) : nil)
                observe(&reducer, .waiting, coverage ? facts(9, 9) : nil)
                if intermediate == .running {
                    XCTAssertEqual(reducer.snapshot.entries.first.map(transition), "running->waiting")
                    XCTAssertTrue(try XCTUnwrap(reducer.snapshot.entries.first).isStatusEdge)
                } else if !coverage {
                    XCTAssertTrue(reducer.snapshot.entries.isEmpty)
                }
            }
        }
    }

    func testOlderPaymentPreservesNewerWaitingEdgeAndIndependentAttention() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(9, 9))
        let receipt = Reducer.Receipt(snapshot: reducer.snapshot)
        observe(&reducer, .waiting, facts(9, 9))
        XCTAssertEqual(requestAttention(0, reducer: &reducer), .accepted)
        let waiting = try XCTUnwrap(reducer.snapshot.entries.first)
        reducer.apply(receipt)
        XCTAssertEqual(reducer.deliveredRunThrough(for: waiting.reference), 9)
        let stillWaiting = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(stillWaiting.fromStatus, waiting.fromStatus)
        XCTAssertEqual(stillWaiting.toStatus, waiting.toStatus)
        XCTAssertEqual(stillWaiting.edgeSequence, waiting.edgeSequence)
        XCTAssertEqual(stillWaiting.changeSequence, waiting.changeSequence)
        XCTAssertEqual(reducer.snapshot.attentionRequests.count, 1)
    }
}

extension AgentSessionLinkPassiveStatusNoticeTests {
    func testF5ReceiptArrivingAfterQuietClosePaysOldDebtWithoutReawakeningRetainedActionableShape() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(9, 9))
        let receipt = Reducer.Receipt(snapshot: reducer.snapshot)
        let opening = reducer.snapshot.entries.first?.openingSettledThrough
        observe(&reducer, .running, facts(9, 9))
        observe(&reducer, .idle, facts(10, 9))
        XCTAssertEqual(
            reducer.snapshot.entries.first?.openingSettledThrough,
            opening,
            "proven quiet refresh preserves the pending occurrence boundary"
        )
        XCTAssertTrue(try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible)
        reducer.apply(receipt)
        let retained = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(reducer.deliveredRunThrough(for: retained.reference), 9)
        XCTAssertTrue(retained.isStatusEdge, "newer status metadata was not acknowledged by the older receipt")
        XCTAssertFalse(retained.isRoutineWakeEligible, "the live paid position must reach admission without inventing payment for cutoff 10")
        observe(&reducer, .running, facts(10, 9))
        observe(&reducer, .idle, facts(10, 9))
        XCTAssertTrue(
            try XCTUnwrap(reducer.snapshot.entries.first).isRoutineWakeEligible,
            "unexplained close cannot inherit the previous quiet interval"
        )
    }
}

extension AgentSessionLinkPassiveStatusNoticeTests {
    func testUnavailableCacheRejectsRegressingFirstReturnBeforeFreshIdleRecovery() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle, runFacts: facts(8, 8))], linkSetRevision: 1)
        observe(&reducer, .idle, facts(9, 9))
        let reference = try XCTUnwrap(reducer.snapshot.entries.first?.reference)
        observe(&reducer, .unavailable, nil)
        observe(&reducer, .idle, facts(10, 8))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty, "a regressing return is not fresh proof")
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 8)
        observe(&reducer, .idle, facts(10, 9))
        let restored = try XCTUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(restored), "idle->idle")
        XCTAssertEqual(restored.ordinaryThrough, 9)
        XCTAssertTrue(restored.isRoutineWakeEligible)
        reducer.apply(.init(snapshot: reducer.snapshot))
        XCTAssertEqual(reducer.deliveredRunThrough(for: reference), 10)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
    }
}
