import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AgentRunQuietLedgerTests: XCTestCase {
    @MainActor
    func testQuietAndOrdinaryClosuresAdvanceCheckedAggregateFactsOnce() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = fixture.rows(["[ack]"])
        let seal = fixture.seal(rows)
        XCTAssertEqual(seal?.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 0))
        XCTAssertEqual(fixture.seal(fixture.rows(["later prose"])), seal)
        XCTAssertTrue(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: fixture.owner))
        XCTAssertFalse(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: fixture.owner))
        XCTAssertNil(fixture.seal(rows))
        XCTAssertEqual(fixture.ledger.facts, seal?.facts)

        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 20, provider: .codexExec)
        XCTAssertTrue(fixture.ledger.end(owner: successor, authoritativeOwner: successor))
        XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
        let third = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: third, startKey: 30, provider: .codexExec)
        fixture.ledger.markRoutineWake(owner: third, wakeID: UUID())
        _ = fixture.ledger.settle(
            owner: third, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: 29, rangeIsComplete: true, rows: [AgentChatItem]()
        )
        XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 3, ordinaryThrough: 2))
    }

    @MainActor
    func testMissingBeginNeedsAuthoritativeEndAndCannotProveQuiet() {
        var fixture = AgentQuietCheckInFixture()
        XCTAssertNil(fixture.seal())
        fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: fixture.wakeID)
        XCTAssertFalse(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: nil))
        XCTAssertEqual(fixture.ledger.facts, .zero)
        XCTAssertTrue(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: fixture.owner))
        XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertFalse(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: fixture.owner))
        XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty)
    }

    @MainActor
    func testStaleOwnerAndBindingMarksEndsAndSealsCannotMutateSuccessor() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let stale = AgentRunOwnership(
            attemptID: fixture.owner.attemptID,
            binding: AgentRunBindingIdentity(tabID: fixture.owner.binding.tabID, persistentSessionID: fixture.owner.binding.persistentSessionID)
        )
        fixture.ledger.noteOccurrence(owner: stale)
        fixture.ledger.invalidateRange(owner: stale)
        fixture.ledger.markRoutineWake(owner: stale, wakeID: UUID())
        XCTAssertFalse(fixture.ledger.end(owner: stale, authoritativeOwner: fixture.owner))
        XCTAssertNil(fixture.ledger.settle(
            owner: stale, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: 9, rangeIsComplete: true, rows: [AgentChatItem]()
        ))
        XCTAssertEqual(fixture.seal()?.isQuiet, true)
        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 10, provider: .claudeCode)
        fixture.ledger.markRoutineWake(owner: successor, wakeID: UUID())
        fixture.ledger.noteOccurrence(owner: fixture.owner)
        XCTAssertFalse(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: successor))
        XCTAssertNil(fixture.seal())
        let result = fixture.ledger.settle(
            owner: successor, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: 9, rangeIsComplete: true, rows: [AgentChatItem]()
        )
        XCTAssertEqual(result?.isQuiet, true)
        XCTAssertEqual(result?.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 0))
    }

    @MainActor
    func testAbandonedPredecessorIsOrdinaryButSealedPredecessorIsNotRecounted() {
        for sealed in [false, true] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            if sealed { XCTAssertEqual(fixture.seal()?.isQuiet, true) }
            let successor = AgentRunOwnership(binding: fixture.owner.binding)
            fixture.ledger.begin(owner: successor, startKey: 10, provider: .claudeCode)
            XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: sealed ? 0 : 1))
            XCTAssertTrue(fixture.ledger.end(owner: successor, authoritativeOwner: successor))
            XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
        }
    }

    @MainActor
    func testAcceptedOccurrenceIsInsertOnlyAcrossRepeatedBeginAndPhysicalMarks() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin(routine: false)
        fixture.ledger.noteOccurrence(owner: fixture.owner)
        fixture.begin()
        fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: fixture.wakeID)
        XCTAssertEqual(fixture.seal()?.isQuiet, false)
        XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty)
    }

    @MainActor
    func testPhysicalMarkAbsentConflictingAndSameWakeReentry() {
        for variant in 0 ..< 3 {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin(routine: variant != 0)
            if variant == 1 { fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: UUID()) }
            if variant == 2 { fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: fixture.wakeID) }
            XCTAssertEqual(fixture.seal()?.isQuiet, variant == 2)
        }
    }

    @MainActor
    func testDefaultFalseNormalProofTerminalStateSuccessorAndRangeVetoes() {
        for state in [AgentSessionRunState.cancelled, .failed, .running, .waitingForUser, .idle] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            XCTAssertEqual(fixture.seal(state: state)?.isQuiet, false, state.rawValue)
        }
        for variant in 0 ..< 4 {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            if variant == 3 { fixture.ledger.invalidateRange(owner: fixture.owner) }
            XCTAssertEqual(fixture.seal(normal: variant != 0, successor: variant == 1, complete: variant != 2)?.isQuiet, false)
        }
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let defaulted = fixture.ledger.settle(
            owner: fixture.owner, terminalState: .completed, endKey: 9,
            rangeIsComplete: true, rows: [AgentChatItem]()
        )
        XCTAssertEqual(defaulted?.isQuiet, false)
    }

    @MainActor
    func testSealIsImmutableAgainstLateInputMarksRangeLossAndDuplicateBarrier() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = fixture.rows(["[ack]"])
        let original = fixture.seal(rows)
        let hidden = fixture.ledger.hiddenSourceIDs
        XCTAssertFalse(fixture.ledger.isOpen(owner: fixture.owner))
        fixture.ledger.noteOccurrence(owner: fixture.owner)
        fixture.ledger.invalidateRange(owner: fixture.owner)
        fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: UUID())
        XCTAssertEqual(fixture.seal(state: .failed, normal: false, successor: true, complete: false), original)
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, hidden)
    }

    @MainActor
    func testCapturedActiveStatusUsesOpeningFactsAndTerminalStatusUsesSealBeforeEnd() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let opening = fixture.ledger.facts
        let sealed = fixture.seal()
        for state in [AgentSessionRunState.running, .waitingForUser, .waitingForApproval, .waitingForQuestion] {
            XCTAssertEqual(fixture.ledger.sourceFacts(owner: fixture.owner, capturedState: state), opening)
        }
        for state in [AgentSessionRunState.completed, .idle, .cancelled, .failed] {
            XCTAssertEqual(fixture.ledger.sourceFacts(owner: fixture.owner, capturedState: state), sealed?.facts)
        }
        XCTAssertNil(fixture.ledger.sourceFacts(owner: nil, capturedState: .running))
        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 10, provider: .codexExec)
        XCTAssertEqual(fixture.ledger.sourceFacts(owner: successor, capturedState: .running), sealed?.facts)
    }

    @MainActor
    func testExhaustionStaysUnknownWithoutWrappingResetOrQuietProjection() throws {
        XCTAssertNil(AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 3))
        var fixture = AgentQuietCheckInFixture()
        fixture.ledger = try AgentRunQuietLedger(initialFacts: XCTUnwrap(AgentRunQuietFacts(settledThrough: UInt64.max - 1, ordinaryThrough: 7)))
        fixture.begin()
        XCTAssertEqual(fixture.seal()?.facts, AgentRunQuietFacts(settledThrough: UInt64.max, ordinaryThrough: 7))
        let priorHidden = fixture.ledger.hiddenSourceIDs
        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 20, provider: .claudeCode)
        fixture.ledger.markRoutineWake(owner: successor, wakeID: UUID())
        XCTAssertNil(fixture.ledger.facts)
        let result = fixture.ledger.settle(
            owner: successor, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: 19, rangeIsComplete: true, rows: [AgentChatItem]()
        )
        XCTAssertEqual(result?.isQuiet, false)
        XCTAssertNil(result?.facts)
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, priorHidden)
        XCTAssertTrue(fixture.ledger.end(owner: successor, authoritativeOwner: successor))
        let untracked = AgentRunOwnership(binding: fixture.owner.binding)
        XCTAssertTrue(fixture.ledger.end(owner: untracked, authoritativeOwner: untracked))
        fixture.ledger.discardSourceProof(isMaterialized: { _ in false })
        XCTAssertNil(fixture.ledger.facts)
    }

    @MainActor
    func testPendingMarkerSurvivesEndAndUnrelatedRetirementUntilProducerNoCallOrMaterialization() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = fixture.rows(["[ack]"])
        XCTAssertEqual(fixture.seal(rows)?.isQuiet, true)
        XCTAssertTrue(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: fixture.owner))
        // Actual row retirement is not a census of IDs missing from the working suffix.
        fixture.ledger.retireSourceIDs([rows[0].id])
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, [fixture.wakeID])
        let marker = AgentChatItem.laneUpdateAutoWake(wakeID: fixture.wakeID, acceptedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(fixture.ledger.registerHostMarker(marker))
        XCTAssertFalse(fixture.ledger.registerHostMarker(marker))
        fixture.ledger.retireUnmaterializedWake(fixture.wakeID)
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, [fixture.wakeID])
        fixture.ledger.retireSourceIDs([fixture.wakeID])
        XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty)
        XCTAssertTrue(fixture.ledger.hostMarkerIDs.isEmpty)

        var neverAccepted = AgentQuietCheckInFixture()
        neverAccepted.begin()
        _ = neverAccepted.seal()
        neverAccepted.ledger.retireUnmaterializedWake(neverAccepted.wakeID)
        XCTAssertTrue(neverAccepted.ledger.hiddenSourceIDs.isEmpty)
    }

    @MainActor
    func testReloadLosesHidingButKeepsMonotonicFactsAndInvalidatesOpenRange() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = fixture.rows(["[ack]"])
        _ = fixture.seal(rows)
        let settled = fixture.ledger.facts
        let materializedIDs = Set(rows.map(\.id))
        fixture.ledger.discardSourceProof(isMaterialized: materializedIDs.contains)
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, [fixture.wakeID])
        XCTAssertEqual(fixture.ledger.facts, settled)
        XCTAssertEqual(fixture.seal()?.facts, settled)
        XCTAssertEqual(fixture.ledger.hiddenSourceIDs, [fixture.wakeID])
        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 20, provider: .codexExec)
        fixture.ledger.markRoutineWake(owner: successor, wakeID: UUID())
        fixture.ledger.discardSourceProof(isMaterialized: { _ in false })
        let result = fixture.ledger.settle(
            owner: successor, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: 19, rangeIsComplete: true, rows: [AgentChatItem]()
        )
        XCTAssertEqual(result?.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
        XCTAssertEqual(result?.isQuiet, false)
    }
}

extension AgentRunQuietLedgerTests {
    @MainActor
    func testProducerCompletionBeforeAndAfterSealRetiresOnlyUnmaterializedMarker() {
        for beforeSeal in [false, true] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            let rows = fixture.rows(["[ack]"])
            if beforeSeal { fixture.ledger.retireUnmaterializedWake(fixture.wakeID) }
            XCTAssertTrue(fixture.seal(rows)?.isQuiet == true)
            if !beforeSeal { fixture.ledger.retireUnmaterializedWake(fixture.wakeID) }
            XCTAssertEqual(fixture.ledger.hiddenSourceIDs, Set(rows.map(\.id)))
        }
        var materialized = AgentQuietCheckInFixture()
        materialized.begin()
        let marker = AgentChatItem.laneUpdateAutoWake(wakeID: materialized.wakeID, acceptedAt: Date(), sequenceIndex: 10)
        XCTAssertTrue(materialized.ledger.registerHostMarker(marker))
        XCTAssertTrue(materialized.seal([marker])?.isQuiet == true)
        materialized.ledger.retireUnmaterializedWake(materialized.wakeID)
        XCTAssertTrue(materialized.ledger.hiddenSourceIDs.contains(marker.id))
    }

    @MainActor
    func testPriorOrdinaryPhysicalDispatchAndDistinctWakeCannotGainRoutineOrigin() {
        for ordinary in [true, false] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin(routine: false)
            fixture.ledger.recordPhysicalDispatch(owner: fixture.owner, wakeID: UUID(), routineQuietCheckIn: !ordinary, alreadyAcquired: false)
            fixture.ledger.recordPhysicalDispatch(owner: fixture.owner, wakeID: fixture.wakeID, routineQuietCheckIn: true, alreadyAcquired: false)
            XCTAssertFalse(fixture.seal()?.isQuiet == true)
        }
    }
}
