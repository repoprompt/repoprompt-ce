import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class WorkspaceCodemapSelectionGraphIncrementalTests: XCTestCase {
    func testIncrementalDefinitionFanoutAndPartialUnresolvedEvidence() async throws {
        let fixture = try GraphFixture(seed: 1)
        let definitionID = uuid("91000000-0000-0000-0000-000000000001")
        let referenceID = uuid("91000000-0000-0000-0000-000000000002")
        let missingID = uuid("91000000-0000-0000-0000-000000000003")
        let definition = try fixture.slot(
            fileID: definitionID,
            path: "Sources/Definition.swift",
            definitions: ["Target"]
        )
        let reference = try fixture.slot(
            fileID: referenceID,
            path: "Sources/Reference.swift",
            references: ["Target"]
        )
        let missing = try fixture.slot(
            fileID: missingID,
            path: "Sources/Missing.swift",
            references: ["Absent"]
        )
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )

        let firstGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let firstCoverage = try fixture.coverage(slots: [definition, reference, missing], complete: false)
        let checkpoint = try fixture.checkpoint(
            slots: [definition, reference, missing],
            coverage: firstCoverage,
            generation: firstGeneration
        )
        guard case let .committed(firstRevision, _, changedCount, affectedCount, true) = await graph.apply(
            .resync(checkpoint: checkpoint, generation: firstGeneration)
        ) else { return XCTFail("Expected initial checkpoint commit.") }
        XCTAssertEqual(firstRevision, 1)
        XCTAssertEqual(changedCount, 3)
        XCTAssertEqual(affectedCount, 3)

        let first = try await readySnapshot(graph.latestSnapshot())
        XCTAssertEqual(first.snapshot.outgoingEdgesBySource[referenceID]?.map(\.targetFileID), [definitionID])
        XCTAssertEqual(first.snapshot.reverseEdgesByTarget[definitionID]?.map(\.sourceFileID), [referenceID])
        XCTAssertEqual(first.snapshot.unresolvedBySource[missingID]?.map(\.reason), [.notIndexedYet])

        let renamedDefinition = try fixture.slot(
            fileID: definitionID,
            path: "Sources/Definition.swift",
            requestGeneration: 2,
            definitions: ["Replacement"]
        )
        let secondGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        guard case let .committed(secondRevision, _, changedCount, affectedCount, false) = await graph.apply(
            .diff(
                changedSlots: [renamedDefinition],
                removed: [],
                coverage: firstCoverage,
                generation: secondGeneration
            )
        ) else { return XCTFail("Expected an incremental definition update.") }
        XCTAssertEqual(secondRevision, 2)
        XCTAssertEqual(changedCount, 1)
        XCTAssertEqual(affectedCount, 2, "Only the changed node and the name-dependent source should be rebuilt.")
        let second = try await readySnapshot(graph.latestSnapshot())
        XCTAssertNil(second.snapshot.outgoingEdgesBySource[referenceID])
        XCTAssertEqual(second.snapshot.unresolvedBySource[referenceID]?.map(\.reason), [.notIndexedYet])

        let completeCoverage = try fixture.coverage(
            slots: [renamedDefinition, reference, missing],
            complete: true
        )
        let thirdGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 3)
        guard case let .committed(thirdRevision, _, _, coverageAffectedCount, false) = await graph.apply(
            .diff(
                changedSlots: [],
                removed: [],
                coverage: completeCoverage,
                generation: thirdGeneration
            )
        ) else { return XCTFail("Expected a coverage-only incremental commit.") }
        XCTAssertEqual(thirdRevision, 3)
        XCTAssertEqual(coverageAffectedCount, 3)
        let third = try await readySnapshot(graph.latestSnapshot())
        XCTAssertEqual(third.snapshot.unresolvedBySource[referenceID]?.map(\.reason), [.missing])
        XCTAssertEqual(third.snapshot.unresolvedBySource[missingID]?.map(\.reason), [.missing])
        let diagnostics = await graph.incrementalAccounting()
        XCTAssertEqual(diagnostics.diffPullCount, 2)
        XCTAssertEqual(diagnostics.resyncPullCount, 1)
        XCTAssertEqual(diagnostics.lastChangedFileCount, 0)
        XCTAssertEqual(diagnostics.lastAffectedSourceCount, 3)
        XCTAssertEqual(diagnostics.totalChangedFileCount, 4)
        XCTAssertEqual(diagnostics.totalAffectedSourceCount, 8)
        XCTAssertNotNil(diagnostics.lastApplyDurationMilliseconds)
        XCTAssertEqual(diagnostics.observedToAppliedGenerationLag, 0)
    }

    func testDestructiveRemovalFencesAtomicallyAndReceiptsRevalidateCumulatively() async throws {
        let fixture = try GraphFixture(seed: 2)
        let deletedID = uuid("92000000-0000-0000-0000-000000000001")
        let survivorID = uuid("92000000-0000-0000-0000-000000000002")
        let deleted = try fixture.slot(fileID: deletedID, path: "Deleted.swift", definitions: ["Gone"])
        let survivor = try fixture.slot(fileID: survivorID, path: "Survivor.swift", references: ["Gone"])
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )
        let firstGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let coverage = try fixture.coverage(slots: [deleted, survivor], complete: true)
        let checkpoint = try fixture.checkpoint(
            slots: [deleted, survivor],
            coverage: coverage,
            generation: firstGeneration
        )
        _ = await graph.apply(.resync(checkpoint: checkpoint, generation: firstGeneration))
        let before = try await readySnapshot(graph.latestSnapshot())
        let removal = try XCTUnwrap(WorkspaceCodemapGraphRemoval(
            rootEpoch: fixture.rootEpoch,
            fileID: deletedID,
            standardizedRelativePath: deleted.standardizedRelativePath,
            reason: .deleted
        ))
        let survivorCoverage = try fixture.coverage(slots: [survivor], complete: true)
        let secondGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        guard case .committed = await graph.apply(.diff(
            changedSlots: [],
            removed: [removal],
            coverage: survivorCoverage,
            generation: secondGeneration
        )) else { return XCTFail("Expected destructive diff commit.") }

        let after = try await readySnapshot(graph.latestSnapshot())
        XCTAssertNil(after.snapshot.nodesByFileID[deletedID])
        XCTAssertNil(after.snapshot.outgoingEdgesBySource[survivorID])
        XCTAssertEqual(after.snapshot.unresolvedBySource[survivorID]?.map(\.reason), [.missing])
        XCTAssertFalse(after.isFenced(deletedID), "A deleted slot has no current generation to hide.")
        XCTAssertEqual(after.fenceIdentities.map(\.fileID), [deletedID])
        XCTAssertGreaterThan(after.receipt.safetyCounter, before.receipt.safetyCounter)
        let deletedRevalidation = await graph.revalidate(
            before.receipt,
            affectedFileIDs: [deletedID]
        )
        XCTAssertEqual(deletedRevalidation, .invalid(.fencedFileOverlap))
        let survivorRevalidation = await graph.revalidate(
            before.receipt,
            affectedFileIDs: [survivorID]
        )
        XCTAssertEqual(survivorRevalidation, .valid(.current))
        let counter = after.receipt.safetyCounter
        let duplicateFence = await graph.fenceFiles(fileIDs: [deletedID], reason: .deleted)
        XCTAssertEqual(
            duplicateFence,
            .fenced(safetyCounter: counter),
            "Re-fencing an already cumulative ID must be idempotent."
        )
    }

    func testNonPreemptiveApplyKeepsLastCommitQueryableAndAdvancesUnderChurn() async throws {
        let fixture = try GraphFixture(seed: 3)
        let gate = GraphSecondApplyGate()
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority,
            applyBuildHook: { await gate.enter() }
        )
        let fileID = uuid("93000000-0000-0000-0000-000000000001")
        let firstSlot = try fixture.slot(fileID: fileID, path: "Value.swift", definitions: ["V1"])
        let firstGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let firstCoverage = try fixture.coverage(slots: [firstSlot], complete: true)
        let firstCheckpoint = try fixture.checkpoint(
            slots: [firstSlot],
            coverage: firstCoverage,
            generation: firstGeneration
        )
        _ = await graph.apply(.resync(checkpoint: firstCheckpoint, generation: firstGeneration))

        let secondSlot = try fixture.slot(
            fileID: fileID,
            path: "Value.swift",
            requestGeneration: 2,
            definitions: ["V2"]
        )
        let secondGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        let apply = Task {
            await graph.apply(.diff(
                changedSlots: [secondSlot],
                removed: [],
                coverage: firstCoverage,
                generation: secondGeneration
            ))
        }
        await gate.waitUntilBlocked()
        let during = try await readySnapshot(graph.latestSnapshot())
        XCTAssertEqual(during.snapshot.graphRevision, 1)
        XCTAssertNotNil(during.snapshot.definitionPostings["V1"])

        await graph.observe(generation: .init(rawValue: 3))
        let pending = try await readySnapshot(graph.latestSnapshot())
        XCTAssertEqual(pending.freshness, .updatesPending(observedGeneration: .init(rawValue: 3)))
        gate.release()
        guard case let .committed(revision, applied, _, _, false) = await apply.value else {
            return XCTFail("A newer observed generation must not cancel the active apply.")
        }
        XCTAssertEqual(revision, 2)
        XCTAssertEqual(applied, secondGeneration)

        let thirdSlot = try fixture.slot(
            fileID: fileID,
            path: "Value.swift",
            requestGeneration: 3,
            definitions: ["V3"]
        )
        guard case let .committed(finalRevision, finalApplied, _, _, false) = await graph.apply(.diff(
            changedSlots: [thirdSlot],
            removed: [],
            coverage: firstCoverage,
            generation: .init(rawValue: 3)
        )) else { return XCTFail("Expected queued churn to make forward progress.") }
        XCTAssertEqual(finalRevision, 3)
        XCTAssertEqual(finalApplied.rawValue, 3)
    }

    func testLaterOverflowResyncQueuesBehindInFlightResyncAndPreservesPreviousCommit() async throws {
        let fixture = try GraphFixture(seed: 10)
        let gate = GraphSecondApplyGate()
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority,
            applyBuildHook: { await gate.enter() }
        )
        let fileID = UUID()
        let first = try fixture.slot(fileID: fileID, path: "Value.swift", definitions: ["V1"])
        let firstGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let firstCoverage = try fixture.coverage(slots: [first], complete: true)
        _ = try await graph.apply(.resync(
            checkpoint: fixture.checkpoint(
                slots: [first],
                coverage: firstCoverage,
                generation: firstGeneration
            ),
            generation: firstGeneration
        ))

        let second = try fixture.slot(
            fileID: fileID,
            path: "Value.swift",
            requestGeneration: 2,
            definitions: ["V2"]
        )
        let third = try fixture.slot(
            fileID: fileID,
            path: "Value.swift",
            requestGeneration: 3,
            definitions: ["V3"]
        )
        let secondGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        let thirdGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 3)
        let secondCoverage = try fixture.coverage(slots: [second], complete: true)
        let thirdCoverage = try fixture.coverage(slots: [third], complete: true)
        let firstOverflow = Task {
            await graph.apply(.resync(
                checkpoint: try! fixture.checkpoint(
                    slots: [second],
                    coverage: secondCoverage,
                    generation: secondGeneration
                ),
                generation: secondGeneration
            ))
        }
        await gate.waitUntilBlocked()
        let laterOverflow = Task {
            await graph.apply(.resync(
                checkpoint: try! fixture.checkpoint(
                    slots: [third],
                    coverage: thirdCoverage,
                    generation: thirdGeneration
                ),
                generation: thirdGeneration
            ))
        }
        await graph.observe(generation: thirdGeneration)
        let during = try await readySnapshot(graph.latestSnapshot())
        XCTAssertEqual(during.snapshot.graphRevision, 1)
        XCTAssertNotNil(during.snapshot.definitionPostings["V1"])
        XCTAssertEqual(during.freshness, .updatesPending(observedGeneration: thirdGeneration))

        gate.release()
        guard case let .committed(secondRevision, _, _, _, true) = await firstOverflow.value else {
            return XCTFail("The in-flight overflow resync must commit rather than be superseded.")
        }
        guard case let .committed(thirdRevision, applied, _, _, true) = await laterOverflow.value else {
            return XCTFail("The later overflow resync must run after the active pass.")
        }
        XCTAssertEqual(secondRevision, 2)
        XCTAssertEqual(thirdRevision, 3)
        XCTAssertEqual(applied, thirdGeneration)
        let final = try await readySnapshot(graph.latestSnapshot())
        XCTAssertNotNil(final.snapshot.definitionPostings["V3"])
        XCTAssertNil(final.snapshot.definitionPostings["V1"])
    }

    func testWatcherGapCoalescesResyncClearsAndFenceCapRevokes() async throws {
        let fixture = try GraphFixture(seed: 4)
        let policy = try XCTUnwrap(WorkspaceCodemapGraphPolicy(maximumFencedFileIDCount: 1))
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority,
            graphPolicy: policy
        )
        let firstID = uuid("94000000-0000-0000-0000-000000000001")
        let secondID = uuid("94000000-0000-0000-0000-000000000002")
        let first = try fixture.slot(fileID: firstID, path: "First.swift", definitions: ["First"])
        let second = try fixture.slot(fileID: secondID, path: "Second.swift", definitions: ["Second"])
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let coverage = try fixture.coverage(slots: [first, second], complete: true)
        let checkpoint = try fixture.checkpoint(slots: [first, second], coverage: coverage, generation: generation)
        _ = await graph.apply(.resync(checkpoint: checkpoint, generation: generation))

        let started = await graph.beginWatcherGapReconciliation()
        let coalesced = await graph.beginWatcherGapReconciliation()
        XCTAssertEqual(started, .started(attempt: 1))
        XCTAssertEqual(coalesced, .coalesced(attempt: 1))
        let reconcilingBefore = try await readySnapshot(graph.latestSnapshot())
        XCTAssertTrue(reconcilingBefore.reconciling)

        let resyncGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        let resyncCheckpoint = try fixture.checkpoint(
            slots: [first, second],
            coverage: coverage,
            generation: resyncGeneration
        )
        guard case .committed = await graph.apply(
            .resync(checkpoint: resyncCheckpoint, generation: resyncGeneration)
        ) else { return XCTFail("Expected reconciliation resync to commit.") }
        let reconcilingAfter = try await readySnapshot(graph.latestSnapshot())
        XCTAssertTrue(reconcilingAfter.reconciling)
        let followingGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 3)
        let followingCheckpoint = try fixture.checkpoint(
            slots: [first, second],
            coverage: coverage,
            generation: followingGeneration
        )
        guard case .committed = await graph.apply(
            .resync(checkpoint: followingCheckpoint, generation: followingGeneration)
        ) else { return XCTFail("Expected the coalesced following reconciliation to commit.") }
        let reconciled = try await readySnapshot(graph.latestSnapshot())
        XCTAssertFalse(reconciled.reconciling)
        let accounting = await graph.incrementalAccounting()
        XCTAssertEqual(accounting.successfulCommitCount, 3)

        let firstFence = await graph.fenceFiles(fileIDs: [firstID], reason: .deleted)
        XCTAssertEqual(firstFence, .fenced(safetyCounter: 1))
        let secondFence = await graph.fenceFiles(fileIDs: [secondID], reason: .renamed)
        XCTAssertEqual(secondFence, .revoked(.fenceCapacityExceeded))
        let revoked = await graph.latestSnapshot()
        XCTAssertEqual(revoked, .revoked(.fenceCapacityExceeded))
    }

    func testTraverseLatestIsDeterministicAndTruncatesWithoutCrossingRootSnapshots() async throws {
        let fixture = try GraphFixture(seed: 5)
        let seedID = uuid("95000000-0000-0000-0000-000000000001")
        let firstTargetID = uuid("95000000-0000-0000-0000-000000000002")
        let secondTargetID = uuid("95000000-0000-0000-0000-000000000003")
        let seed = try fixture.slot(
            fileID: seedID,
            path: "Sources/Seed.swift",
            references: ["Target"]
        )
        let firstTarget = try fixture.slot(
            fileID: firstTargetID,
            path: "Sources/A.swift",
            definitions: ["Target"]
        )
        let secondTarget = try fixture.slot(
            fileID: secondTargetID,
            path: "Sources/B.swift",
            definitions: ["Target"]
        )
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let slots = [secondTarget, seed, firstTarget]
        let coverage = try fixture.coverage(slots: slots, complete: true)
        let checkpoint = try fixture.checkpoint(slots: slots, coverage: coverage, generation: generation)
        guard case .committed = await graph.apply(.resync(checkpoint: checkpoint, generation: generation)) else {
            return XCTFail("Expected a committed graph snapshot.")
        }

        let graphOnlyBudget = WorkspaceCodemapGraphPolicy.initial.queryBudget(
            maximumTokenCount: 6000,
            includesSignatures: false
        )
        let query = WorkspaceCodemapGraphStructureQuery(
            seedFileIDs: [seedID],
            direction: .referencedDefinitions,
            maximumDepth: 2,
            budget: graphOnlyBudget
        )
        let first = try await graph.traverseLatest(query)
        let repeated = try await graph.traverseLatest(query)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.rootEpoch, fixture.rootEpoch)
        XCTAssertEqual(first.nodes.map(\.fileID), [seedID, firstTargetID, secondTargetID])
        XCTAssertEqual(first.nodes.map(\.depth), [0, 1, 1])
        XCTAssertEqual(
            first.edges.map { [$0.sourceFileID, $0.targetFileID] },
            [[seedID, firstTargetID], [seedID, secondTargetID]]
        )

        let boundedBudget = WorkspaceCodemapGraphQueryBudget(
            maximumTokenCount: 1000,
            maximumNodeCount: 2,
            maximumEdgeCount: 2,
            maximumGraphByteCount: 4096,
            graphEvidenceTokenCount: 1000,
            renderTokenCount: 0
        )
        let bounded = try await graph.traverseLatest(.init(
            seedFileIDs: [seedID],
            direction: .referencedDefinitions,
            maximumDepth: 2,
            budget: boundedBudget
        ))
        XCTAssertEqual(bounded.nodes.map(\.fileID), [seedID, firstTargetID])
        XCTAssertEqual(bounded.truncation?.droppedNodeCount, 1)
        XCTAssertTrue(bounded.issues.contains(.maxTokens))
    }

    func testAutomaticSelectionQueriesCommittedSnapshotWithoutSourceArtifactDemand() async throws {
        let fixture = try GraphFixture(seed: 6)
        let sourceID = uuid("96000000-0000-0000-0000-000000000001")
        let targetID = uuid("96000000-0000-0000-0000-000000000002")
        let source = try fixture.slot(
            fileID: sourceID,
            path: "Sources/Source.swift",
            requestGeneration: 4,
            references: ["Target"]
        )
        let target = try fixture.slot(
            fileID: targetID,
            path: "Sources/Target.swift",
            requestGeneration: 7,
            definitions: ["Target"]
        )
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )
        let coverage = try fixture.coverage(slots: [target, source], complete: true)
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let checkpoint = try fixture.checkpoint(
            slots: [target, source],
            coverage: coverage,
            generation: generation
        )
        guard case .committed = await graph.apply(.resync(checkpoint: checkpoint, generation: generation)) else {
            return XCTFail("Expected committed graph snapshot.")
        }

        let disposition = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 4)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(result) = disposition else {
            return XCTFail("Expected direct committed-snapshot automatic selection.")
        }
        XCTAssertEqual(result.sources, [
            .init(fileID: sourceID, requestGeneration: 4, state: .covered)
        ])
        XCTAssertEqual(result.targets.map(\.fileID), [targetID])
        XCTAssertEqual(result.targets.map(\.requestGeneration), [7])
        XCTAssertEqual(result.targets.map(\.standardizedRelativePath), ["Sources/Target.swift"])
        XCTAssertEqual(result.receipt.rootEpoch, fixture.rootEpoch)

        let stale = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 3)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(staleResult) = stale else {
            return XCTFail("A stale source is reported from the committed ledger, not artifact loading.")
        }
        XCTAssertEqual(staleResult.targets, [])
        XCTAssertEqual(staleResult.sources, [
            .init(
                fileID: sourceID,
                requestGeneration: 3,
                state: .staleGeneration(expected: 3, committed: 4)
            )
        ])
    }

    func testAutomaticSelectionBudgetLimitsAcceptExactCountsAndRejectOneOver() async throws {
        let fixture = try GraphFixture(seed: 12)
        let sourceID = uuid("9C000000-0000-0000-0000-000000000001")
        let firstTargetID = uuid("9C000000-0000-0000-0000-000000000002")
        let secondTargetID = uuid("9C000000-0000-0000-0000-000000000003")
        let source = try fixture.slot(
            fileID: sourceID,
            path: "Sources/Source.swift",
            references: ["FirstTarget", "SecondTarget", "MissingOne", "MissingTwo"]
        )
        let firstTarget = try fixture.slot(
            fileID: firstTargetID,
            path: "Sources/First.swift",
            definitions: ["FirstTarget"]
        )
        let secondTarget = try fixture.slot(
            fileID: secondTargetID,
            path: "Sources/Second.swift",
            definitions: ["SecondTarget"]
        )
        let slots = [source, firstTarget, secondTarget]
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let checkpoint = try fixture.checkpoint(
            slots: slots,
            coverage: fixture.coverage(slots: slots, complete: true),
            generation: generation
        )
        guard case .committed = await graph.apply(.resync(checkpoint: checkpoint, generation: generation)) else {
            return XCTFail("Expected the budget fixture to commit.")
        }

        let generous = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(baseline) = generous else {
            return XCTFail("Expected the generous query to establish exact accounting counts.")
        }
        XCTAssertEqual(baseline.targets.map(\.fileID), [firstTargetID, secondTargetID])
        XCTAssertEqual(baseline.resolutionCount, 2)
        XCTAssertEqual(baseline.referenceFailureCount, 2)
        XCTAssertGreaterThan(baseline.materializedByteCount, 0)

        let exact = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: baseline.targets.count,
            maximumResolutionCount: baseline.resolutionCount,
            maximumReferenceFailureCount: baseline.referenceFailureCount,
            maximumByteCount: baseline.materializedByteCount
        ))
        guard case let .ready(exactResult) = exact else {
            return XCTFail("Every exact accounting limit must be accepted.")
        }
        XCTAssertEqual(exactResult, baseline)

        let targetOneOver = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: baseline.targets.count - 1,
            maximumResolutionCount: baseline.resolutionCount,
            maximumReferenceFailureCount: baseline.referenceFailureCount,
            maximumByteCount: baseline.materializedByteCount
        ))
        XCTAssertEqual(targetOneOver, .budget(.targetLimit(
            attempted: baseline.targets.count,
            limit: baseline.targets.count - 1
        )))

        let resolutionOneOver = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: baseline.targets.count,
            maximumResolutionCount: baseline.resolutionCount - 1,
            maximumReferenceFailureCount: baseline.referenceFailureCount,
            maximumByteCount: baseline.materializedByteCount
        ))
        XCTAssertEqual(resolutionOneOver, .budget(.resolutionLimit(
            attempted: baseline.resolutionCount,
            limit: baseline.resolutionCount - 1
        )))

        let failureOneOver = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: baseline.targets.count,
            maximumResolutionCount: baseline.resolutionCount,
            maximumReferenceFailureCount: baseline.referenceFailureCount - 1,
            maximumByteCount: baseline.materializedByteCount
        ))
        XCTAssertEqual(failureOneOver, .budget(.referenceFailureLimit(
            attempted: baseline.referenceFailureCount,
            limit: baseline.referenceFailureCount - 1
        )))

        let byteOneOver = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: baseline.targets.count,
            maximumResolutionCount: baseline.resolutionCount,
            maximumReferenceFailureCount: baseline.referenceFailureCount,
            maximumByteCount: baseline.materializedByteCount - 1
        ))
        XCTAssertEqual(byteOneOver, .budget(.byteLimit(
            attempted: baseline.materializedByteCount,
            limit: baseline.materializedByteCount - 1
        )))
    }

    func testSameFileIDRenameFencesOnlyRetiredSlotMidDiffAndMidResync() async throws {
        let fixture = try GraphFixture(seed: 7)
        let sourceID = uuid("98000000-0000-0000-0000-000000000001")
        let targetID = uuid("98000000-0000-0000-0000-000000000002")
        let oldSource = try fixture.slot(
            fileID: sourceID,
            path: "Sources/Old.swift",
            references: ["Target"]
        )
        let target = try fixture.slot(
            fileID: targetID,
            path: "Sources/Target.swift",
            definitions: ["Target"]
        )
        let gate = GraphRenameApplyGate()
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority,
            applyBuildHook: { await gate.enter() }
        )
        let firstGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let firstCoverage = try fixture.coverage(slots: [oldSource, target], complete: true)
        _ = try await graph.apply(.resync(
            checkpoint: fixture.checkpoint(
                slots: [oldSource, target],
                coverage: firstCoverage,
                generation: firstGeneration
            ),
            generation: firstGeneration
        ))
        let oldReceipt = try await readySnapshot(graph.latestSnapshot()).receipt

        let renamed = try fixture.slot(
            fileID: sourceID,
            path: "Sources/Renamed.swift",
            requestGeneration: 2,
            references: ["Target"]
        )
        let removal = try XCTUnwrap(WorkspaceCodemapGraphRemoval(
            rootEpoch: fixture.rootEpoch,
            fileID: sourceID,
            standardizedRelativePath: oldSource.standardizedRelativePath,
            reason: .renamed
        ))
        let secondGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 2)
        let apply = Task {
            await graph.apply(.diff(
                changedSlots: [renamed],
                removed: [removal],
                coverage: try! fixture.coverage(slots: [renamed, target], complete: true),
                generation: secondGeneration
            ))
        }
        await gate.waitUntilDiffBlocked()
        let initialFence = await graph.fenceFiles(fileIDs: [sourceID], reason: .renamed)
        XCTAssertEqual(initialFence, .fenced(safetyCounter: 1))
        let during = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 1)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(duringResult) = during else { return XCTFail("Expected pinned old snapshot.") }
        XCTAssertEqual(duringResult.sources.map(\.state), [.fenced])
        gate.releaseDiff()
        guard case .committed = await apply.value else {
            return XCTFail("Expected rename diff candidate to commit.")
        }

        let replacement = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 2)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(replacementResult) = replacement else { return XCTFail("Expected renamed slot query.") }
        XCTAssertEqual(replacementResult.sources.map(\.state), [.covered])
        XCTAssertEqual(replacementResult.targets.map(\.fileID), [targetID])
        let replacementReceipt = replacementResult.receipt
        let oldRevalidation = await graph.revalidate(oldReceipt, affectedFileIDs: [sourceID])
        XCTAssertEqual(oldRevalidation, .invalid(.fencedFileOverlap))

        _ = await graph.beginWatcherGapReconciliation()
        let resynced = try fixture.slot(
            fileID: sourceID,
            path: "Sources/Resynced.swift",
            requestGeneration: 3,
            references: ["Target"]
        )
        let thirdGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 3)
        let thirdCoverage = try fixture.coverage(slots: [resynced, target], complete: true)
        let resync = Task {
            await graph.apply(.resync(
                checkpoint: try! fixture.checkpoint(
                    slots: [resynced, target],
                    coverage: thirdCoverage,
                    generation: thirdGeneration
                ),
                generation: thirdGeneration
            ))
        }
        await gate.waitUntilResyncBlocked()
        let resyncFence = await graph.fenceFiles(fileIDs: [sourceID], reason: .renamed)
        XCTAssertEqual(resyncFence, .fenced(safetyCounter: 2))
        let duringResync = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 2)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(duringResyncResult) = duringResync else {
            return XCTFail("Expected the prior snapshot during resync.")
        }
        XCTAssertEqual(duringResyncResult.sources.map(\.state), [.fenced])
        gate.releaseResync()
        guard case .committed = await resync.value else {
            return XCTFail("Expected rename resync candidate to commit.")
        }
        let replacementRevalidation = await graph.revalidate(
            replacementReceipt,
            affectedFileIDs: [sourceID]
        )
        XCTAssertEqual(replacementRevalidation, .invalid(.fencedFileOverlap))
        let resyncQuery = await graph.automaticSelectionLatest(.init(
            rootEpoch: fixture.rootEpoch,
            sources: [.init(fileID: sourceID, requestGeneration: 3)],
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 10,
            maximumByteCount: 4096
        ))
        guard case let .ready(resyncResult) = resyncQuery else { return XCTFail("Expected resynced rename query.") }
        XCTAssertEqual(resyncResult.sources.map(\.state), [.covered])
        XCTAssertEqual(resyncResult.targets.map(\.fileID), [targetID])
    }

    func testReconciliationDeadlineActivelyRevokesWithoutFailureCallback() async throws {
        let fixture = try GraphFixture(seed: 8)
        let deadline = TestReleaseFence(name: "graph reconciliation deadline")
        let policy = try XCTUnwrap(WorkspaceCodemapGraphPolicy(
            maximumReconciliationWallClockMilliseconds: 25
        ))
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority,
            graphPolicy: policy,
            uptimeNanoseconds: { 1_000_000 },
            reconciliationWaiter: { requested in
                XCTAssertEqual(requested, 25_000_000)
                await deadline.enterAndWait()
            }
        )
        let slot = try fixture.slot(
            fileID: uuid("99000000-0000-0000-0000-000000000001"),
            path: "Sources/Value.swift",
            definitions: ["Value"]
        )
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let coverage = try fixture.coverage(slots: [slot], complete: false)
        _ = try await graph.apply(.resync(
            checkpoint: fixture.checkpoint(slots: [slot], coverage: coverage, generation: generation),
            generation: generation
        ))
        let reconciliation = await graph.beginWatcherGapReconciliation()
        XCTAssertEqual(reconciliation, .started(attempt: 1))
        let deadlineEntered = await deadline.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
        XCTAssertTrue(deadlineEntered)
        let usable = try await readySnapshot(graph.latestSnapshot())
        XCTAssertTrue(usable.reconciling)
        deadline.release()
        for _ in 0 ..< 100 {
            if await graph.latestSnapshot() == .revoked(.reconciliationFailed) { break }
            await Task.yield()
        }
        let expired = await graph.latestSnapshot()
        XCTAssertEqual(expired, .revoked(.reconciliationFailed))
        let accounting = await graph.incrementalAccounting()
        XCTAssertEqual(accounting.reconciliationStartedCount, 1)
        XCTAssertEqual(accounting.reconciliationRevokedCount, 1)
        XCTAssertFalse(accounting.reconciling)
    }

    func testRootShutdownCooperativelyAbortsLargeCandidateWithoutPreemptingNormalChurn() async throws {
        let fixture = try GraphFixture(seed: 9)
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: fixture.rootEpoch,
            repositoryAuthority: fixture.authority
        )
        var slots: [WorkspaceCodemapGraphSlot] = []
        slots.reserveCapacity(12000)
        for index in 0 ..< 12000 {
            try slots.append(fixture.slot(
                fileID: UUID(),
                path: "Sources/Generated/Value\(index).swift",
                definitions: ["Value\(index)"]
            ))
        }
        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        let coverage = try fixture.coverage(slots: slots, complete: true)
        let checkpoint = try fixture.checkpoint(slots: slots, coverage: coverage, generation: generation)
        let apply = Task {
            await graph.apply(.resync(checkpoint: checkpoint, generation: generation))
        }
        var observedCandidate = false
        for _ in 0 ..< 10000 {
            if await graph.hasActiveCandidateBuildForTesting() {
                observedCandidate = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(observedCandidate, "The large candidate must enter detached construction before shutdown.")
        let clock = ContinuousClock()
        let started = clock.now
        await graph.shutdown(reason: .rootUnloaded)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        let applyDisposition = await apply.value
        XCTAssertEqual(applyDisposition, .cancelled)
        let accounting = await graph.incrementalAccounting()
        XCTAssertEqual(accounting.revocationReason, .rootUnloaded)
        XCTAssertFalse(accounting.activeApply)
    }

    func testMixedRootAggregationIsDeterministicAndPreservesSuccessfulTargets() throws {
        let firstEpoch = WorkspaceCodemapRootEpoch(
            rootID: uuid("97000000-0000-0000-0000-000000000001"),
            rootLifetimeID: uuid("97000000-0000-0000-0000-000000000011")
        )
        let secondEpoch = WorkspaceCodemapRootEpoch(
            rootID: uuid("97000000-0000-0000-0000-000000000002"),
            rootLifetimeID: uuid("97000000-0000-0000-0000-000000000022")
        )
        let target = try WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: secondEpoch,
            fileID: uuid("97000000-0000-0000-0000-000000000003"),
            catalogGeneration: 8,
            requestGeneration: 5,
            logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "Second",
                standardizedRelativePath: "Sources/Target.swift"
            ))
        )
        let failed = WorkspaceCodemapAutomaticSelectionRootResult(
            rootEpoch: firstEpoch,
            status: .unavailable,
            targets: [],
            sources: [],
            issues: [.graphUnavailable(firstEpoch)],
            coverage: nil,
            graphTargetCount: 0,
            graphResolutionCount: 0,
            graphReferenceFailureCount: 0,
            graphByteCount: 0,
            receipt: nil
        )
        let successful = WorkspaceCodemapAutomaticSelectionRootResult(
            rootEpoch: secondEpoch,
            status: .ok,
            targets: [target],
            sources: [],
            issues: [],
            coverage: nil,
            graphTargetCount: 1,
            graphResolutionCount: 1,
            graphReferenceFailureCount: 0,
            graphByteCount: 128,
            receipt: nil
        )

        let result = WorkspaceCodemapAutomaticSelectionResult(roots: [successful, failed])
        XCTAssertEqual(result.roots.map(\.rootEpoch), [firstEpoch, secondEpoch])
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.targets, [target], "One root failure must not discard another root's targets.")
        XCTAssertEqual(result.issues, [.graphUnavailable(firstEpoch)])
    }

    private func readySnapshot(
        _ disposition: WorkspaceCodemapGraphLatestSnapshotDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkspaceCodemapGraphPinnedSnapshot {
        guard case let .ready(snapshot) = disposition else {
            XCTFail("Expected a committed snapshot.", file: file, line: line)
            throw GraphTestError.snapshotUnavailable
        }
        return snapshot
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private struct GraphFixture {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let authority: WorkspaceCodemapRepositoryAuthorityToken
    let pipeline: CodeMapPipelineIdentity
    let catalogToken: WorkspaceCodemapGraphIndexCatalogToken

    init(seed: UInt8) throws {
        rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: UUID(uuid: (seed, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            rootLifetimeID: UUID(uuid: (seed, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        )
        authority = try WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: UInt64(seed),
            repositoryNamespace: GitBlobRepositoryNamespace(rawValue: String(repeating: "cd", count: 32)),
            objectFormat: .sha1,
            repositoryBindingEpoch: "repository-\(seed)",
            worktreeBindingEpoch: "worktree-\(seed)",
            layoutGeneration: "layout-\(seed)",
            indexGeneration: "index-\(seed)",
            checkoutConfigurationGeneration: "checkout-\(seed)",
            attributeGeneration: "attributes-\(seed)",
            sparseGeneration: "sparse-\(seed)",
            metadataGeneration: "metadata-\(seed)"
        )
        pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        catalogToken = WorkspaceCodemapGraphIndexCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: 1,
            ingressGeneration: 1,
            graphIndexInvalidationGeneration: 1
        )
    }

    func slot(
        fileID: UUID,
        path: String,
        requestGeneration: UInt64 = 1,
        definitions: [String] = [],
        references: [String] = []
    ) throws -> WorkspaceCodemapGraphSlot {
        let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: "/workspace",
            standardizedRelativePath: path,
            standardizedFullPath: "/workspace/\(path)"
        ))
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: UInt8(requestGeneration), count: 32)),
                rawByteCount: requestGeneration,
                pipelineIdentity: pipeline
            ),
            definitions: definitions,
            references: references
        )
        let state: WorkspaceCodemapGraphSlotState = definitions.isEmpty && references.isEmpty
            ? .empty(contribution)
            : .contributed(contribution)
        return try WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: identity,
            requestGeneration: requestGeneration,
            pathGeneration: requestGeneration,
            pipelineIdentity: pipeline,
            state: state,
            diagnostics: .init(
                contributionDigest: contribution.contributionDigest,
                source: .graphIndex
            )
        ).get()
    }

    func coverage(
        slots: [WorkspaceCodemapGraphSlot],
        complete: Bool
    ) throws -> WorkspaceCodemapGraphCatalogCoverage {
        let contributed = UInt64(slots.count(where: { slot in
            if case .contributed = slot.state { return true }
            return false
        }))
        let empty = UInt64(slots.count(where: { slot in
            if case .empty = slot.state { return true }
            return false
        }))
        let pending = UInt64(slots.count(where: { slot in
            if case .pending = slot.state { return true }
            return false
        }))
        return try WorkspaceCodemapGraphCatalogCoverage.validated(
            rootEpoch: rootEpoch,
            catalogWatermark: catalogToken,
            enumerationState: complete ? .complete : .partial,
            supportedCount: UInt64(slots.count),
            classifiedCount: UInt64(slots.count) - pending,
            pendingCount: pending,
            contributedCount: contributed,
            emptyCount: empty,
            terminalArtifactCount: 0,
            terminalExcludedCount: 0
        ).get()
    }

    func checkpoint(
        slots: [WorkspaceCodemapGraphSlot],
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration
    ) throws -> WorkspaceCodemapGraphCheckpoint {
        try WorkspaceCodemapGraphCheckpoint.validated(
            rootEpoch: rootEpoch,
            repositoryAuthority: authority,
            generation: generation,
            schemaVersion: CodeMapSelectionGraphContribution.currentSchemaVersion,
            policyVersion: CodeMapSelectionGraphContribution.currentPolicyVersion,
            slots: slots,
            coverage: coverage
        ).get()
    }
}

private final class GraphSecondApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let fence = TestReleaseFence(name: "graph second apply gate")
    private var entryCount = 0

    func enter() async {
        let shouldBlock = lock.withLock { () -> Bool in
            entryCount += 1
            return entryCount == 2
        }
        if shouldBlock { await fence.enterAndWait() }
    }

    func waitUntilBlocked() async {
        _ = await fence.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
    }

    func release() {
        fence.release()
    }
}

private final class GraphRenameApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let diffFence = TestReleaseFence(name: "graph rename diff apply gate")
    private let resyncFence = TestReleaseFence(name: "graph rename resync apply gate")
    private var entryCount = 0

    func enter() async {
        let entry = lock.withLock { () -> Int in
            entryCount += 1
            return entryCount
        }
        switch entry {
        case 2:
            await diffFence.enterAndWait()
        case 3:
            await resyncFence.enterAndWait()
        default:
            break
        }
    }

    func waitUntilDiffBlocked() async {
        _ = await diffFence.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
    }

    func releaseDiff() {
        diffFence.release()
    }

    func waitUntilResyncBlocked() async {
        _ = await resyncFence.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
    }

    func releaseResync() {
        resyncFence.release()
    }
}

private enum GraphTestError: Error {
    case snapshotUnavailable
}
