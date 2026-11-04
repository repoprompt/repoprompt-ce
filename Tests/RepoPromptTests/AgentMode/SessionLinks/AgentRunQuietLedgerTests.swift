import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AgentRunQuietLedgerTests: XCTestCase {
    @MainActor
    func testQuietAndOrdinaryClosuresAdvanceCheckedAggregateFactsOnce() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = try fixture.declarationRows()
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
        XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 3, ordinaryThrough: 3), "An undeclared silent third close remains ordinary")
    }

    @MainActor
    func testDeclarationRangeRequiresCompleteOrderedUniqueAllocatedRows() throws {
        for corruption in ["none", "lost-prefix", "lost-tail", "reordered", "duplicate-identity", "streaming"] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            var rows = try fixture.declarationRows()
            switch corruption {
            case "lost-prefix": rows.removeFirst()
            case "lost-tail": rows.removeLast()
            case "reordered": rows.reverse()
            case "duplicate-identity":
                rows[1] = AgentChatItem(id: rows[0].id, timestamp: rows[1].timestamp, kind: .toolResult, text: rows[1].text, toolName: rows[1].toolName, toolInvocationID: rows[1].toolInvocationID, toolResultJSON: rows[1].toolResultJSON, toolIsError: false, sequenceIndex: 11)
            case "streaming": rows[1].isStreaming = true
            default: break
            }
            let seal = fixture.ledger.settle(owner: fixture.owner, terminalState: .completed, classifiesQuietCheckIn: true, endKey: 11, rangeIsComplete: true, rows: rows)
            XCTAssertEqual(seal?.isQuiet, corruption == "none", corruption)
        }
    }

    @MainActor
    func testDeclarationMarkerRequiresPositiveRegistrationAndCanonicalSource() throws {
        for variant in ["valid", "unregistered", "changed-text", "changed-kind", "forged-identity"] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            let declared = try fixture.declarationRows()
            var marker = AgentChatItem.laneUpdateAutoWake(wakeID: fixture.wakeID, acceptedAt: Date(timeIntervalSince1970: 1), sequenceIndex: 12)
            if variant != "unregistered" { XCTAssertTrue(fixture.ledger.registerHostMarker(marker)) }
            switch variant {
            case "changed-text": marker.text += " changed"
            case "changed-kind": marker.kind = .user
            case "forged-identity": marker = AgentChatItem(kind: .system, text: marker.text, sequenceIndex: 12)
            default: break
            }
            XCTAssertEqual(fixture.seal(declared + [marker])?.isQuiet, variant == "valid", variant)
        }
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
    func testStaleOwnerAndBindingMarksEndsAndSealsCannotMutateSuccessor() throws {
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
        XCTAssertEqual(try fixture.sealDeclaration()?.isQuiet, true)
        let successor = AgentRunOwnership(binding: fixture.owner.binding)
        fixture.ledger.begin(owner: successor, startKey: 10, provider: .claudeCode)
        fixture.ledger.markRoutineWake(owner: successor, wakeID: UUID())
        fixture.ledger.noteOccurrence(owner: fixture.owner)
        XCTAssertFalse(fixture.ledger.end(owner: fixture.owner, authoritativeOwner: successor))
        XCTAssertNil(fixture.seal())
        let successorRows = try fixture.declarationRows(owner: successor)
        let result = try fixture.ledger.settle(
            owner: successor, terminalState: .completed, classifiesQuietCheckIn: true,
            endKey: XCTUnwrap(successorRows.last?.sequenceIndex), rangeIsComplete: true, rows: successorRows
        )
        XCTAssertEqual(result?.isQuiet, true)
        XCTAssertEqual(result?.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 0))
    }

    @MainActor
    func testAbandonedPredecessorIsOrdinaryButSealedPredecessorIsNotRecounted() throws {
        for sealed in [false, true] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            if sealed { XCTAssertEqual(try fixture.sealDeclaration()?.isQuiet, true) }
            let successor = AgentRunOwnership(binding: fixture.owner.binding)
            fixture.ledger.begin(owner: successor, startKey: 10, provider: .claudeCode)
            XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: sealed ? 0 : 1))
            XCTAssertTrue(fixture.ledger.end(owner: successor, authoritativeOwner: successor))
            XCTAssertEqual(fixture.ledger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
        }
    }

    @MainActor
    func testAcceptedOccurrenceIsInsertOnlyAcrossRepeatedBeginAndPhysicalMarks() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin(routine: false)
        fixture.ledger.noteOccurrence(owner: fixture.owner)
        fixture.begin()
        fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: fixture.wakeID)
        XCTAssertEqual(try fixture.sealDeclaration()?.isQuiet, false)
        XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty)
    }

    @MainActor
    func testPhysicalMarkAbsentConflictingAndSameWakeReentry() throws {
        for variant in 0 ..< 3 {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin(routine: variant != 0)
            if variant == 1 { fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: UUID()) }
            if variant == 2 { fixture.ledger.markRoutineWake(owner: fixture.owner, wakeID: fixture.wakeID) }
            XCTAssertEqual(try fixture.sealDeclaration()?.isQuiet, variant == 2)
        }
    }

    @MainActor
    func testDefaultFalseNormalProofTerminalStateSuccessorAndRangeVetoes() throws {
        for state in [AgentSessionRunState.cancelled, .failed, .running, .waitingForUser, .idle] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            let rows = try fixture.declarationRows()
            XCTAssertEqual(fixture.seal(rows, state: state)?.isQuiet, false, state.rawValue)
        }
        for variant in 0 ..< 4 {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            let rows = try fixture.declarationRows()
            if variant == 3 { fixture.ledger.invalidateRange(owner: fixture.owner) }
            XCTAssertEqual(fixture.seal(rows, normal: variant != 0, successor: variant == 1, complete: variant != 2)?.isQuiet, false)
        }
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let declared = try fixture.declarationRows()
        let defaulted = try fixture.ledger.settle(
            owner: fixture.owner, terminalState: .completed, endKey: XCTUnwrap(declared.last?.sequenceIndex),
            rangeIsComplete: true, rows: declared
        )
        XCTAssertEqual(defaulted?.isQuiet, false)
    }

    @MainActor
    func testSealIsImmutableAgainstLateInputMarksRangeLossAndDuplicateBarrier() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = try fixture.declarationRows()
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
    func testCapturedActiveStatusUsesOpeningFactsAndTerminalStatusUsesSealBeforeEnd() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let opening = fixture.ledger.facts
        let sealed = try fixture.sealDeclaration()
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
        XCTAssertEqual(try fixture.sealDeclaration()?.facts, AgentRunQuietFacts(settledThrough: UInt64.max, ordinaryThrough: 7))
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
    func testPendingMarkerSurvivesEndAndUnrelatedRetirementUntilProducerNoCallOrMaterialization() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = try fixture.declarationRows()
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
    func testDiscardingMaterializedLiveProofKeepsFactsAndInvalidatesOpenRange() throws {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        let rows = try fixture.declarationRows()
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
    func testProducerCompletionBeforeAndAfterSealRetiresOnlyUnmaterializedMarker() throws {
        for beforeSeal in [false, true] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            let rows = try fixture.declarationRows()
            if beforeSeal { fixture.ledger.retireUnmaterializedWake(fixture.wakeID) }
            XCTAssertTrue(fixture.seal(rows)?.isQuiet == true)
            if !beforeSeal { fixture.ledger.retireUnmaterializedWake(fixture.wakeID) }
            XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty, "Only the session stamp owner owns materialized row omission; the ledger owns the pending marker")
        }
        var materialized = AgentQuietCheckInFixture()
        materialized.begin()
        let marker = AgentChatItem.laneUpdateAutoWake(wakeID: materialized.wakeID, acceptedAt: Date(), sequenceIndex: 10)
        XCTAssertTrue(materialized.ledger.registerHostMarker(marker))
        let declared = try materialized.declarationRows(startKey: 11)
        XCTAssertTrue(materialized.seal([marker] + declared)?.isQuiet == true)
        materialized.ledger.retireUnmaterializedWake(materialized.wakeID)
        XCTAssertTrue(materialized.ledger.hiddenSourceIDs.contains(marker.id))
    }

    @MainActor
    func testPriorOrdinaryPhysicalDispatchAndDistinctWakeCannotGainRoutineOrigin() throws {
        for ordinary in [true, false] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin(routine: false)
            fixture.ledger.recordPhysicalDispatch(owner: fixture.owner, wakeID: UUID(), routineQuietCheckIn: !ordinary, alreadyAcquired: false)
            fixture.ledger.recordPhysicalDispatch(owner: fixture.owner, wakeID: fixture.wakeID, routineQuietCheckIn: true, alreadyAcquired: false)
            XCTAssertFalse(try fixture.sealDeclaration()?.isQuiet == true)
        }
    }
}
