import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapSelectionGraphTests: XCTestCase {
    func testStrictQueryIsTargetlessUntilExactProjectionSeal() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let value = snapshot(authority: authority, bindings: bindings, generation: 1)
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        try await requirePublished(graph.rebuild(from: value))

        let query = WorkspaceCodemapSelectionGraphRuntimeQuery(
            key: .init(snapshot: value),
            selectedSources: [.init(
                fileID: bindings[0].identity.fileID,
                requestGeneration: 7
            )]
        )
        guard case let .definitionUniverse(.incomplete(progress, remainingCount, retry)) =
            await graph.query(query)
        else { return XCTFail("Live demand must not prove the definition universe.") }
        XCTAssertEqual(progress, .notStarted)
        XCTAssertNil(remainingCount)
        XCTAssertNil(retry)

        let proof = try await publishCompleteProjection(on: graph, snapshot: value, seal: false)
        guard case let .definitionUniverse(.incomplete(stagedProgress, remaining, _)) =
            await graph.query(query)
        else { return XCTFail("A staged generation must remain explicitly incomplete.") }
        XCTAssertEqual(stagedProgress.counts.supportedCandidateCount, 2)
        XCTAssertEqual(remaining, 0)
        _ = try await publishCompleteProjection(on: graph, snapshot: value, seal: false)
        let duplicateAccounting = await graph.accounting()
        XCTAssertEqual(duplicateAccounting.acceptedProjectionSegmentCount, 1)
        XCTAssertEqual(duplicateAccounting.exactDuplicateProjectionSegmentCount, 1)
        guard case .accepted = await graph.applyProjectionSnapshot(.seal(proof)) else {
            return XCTFail("Expected the exact proof to seal staged coverage.")
        }
        let result = try await requireReady(graph.query(query))
        XCTAssertEqual(result.targets.map(\.fileID), [bindings[1].identity.fileID])
        XCTAssertEqual(
            result.definitionUniverseCoverage,
            .complete(
                proof: proof,
                candidateCount: proof.candidateCount,
                contributedCount: proof.contributedCount,
                terminalCount: proof.terminalCount
            )
        )
    }

    func testEquivalentProjectionSuccessorResealsGenerationOneToThreeWithoutRebuild() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let first = snapshot(authority: authority, bindings: bindings, generation: 1)
        let successorSnapshot = snapshot(authority: authority, bindings: bindings, generation: 3)
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        let firstProof = try await publishCompleteProjection(on: graph, snapshot: first)
        let firstAccounting = await graph.accounting()
        let successorProof = try XCTUnwrap(firstProof.successor(
            contributionGeneration: successorSnapshot.contributionGeneration
        ))
        let successorKey = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: successorSnapshot)
        let staleDisposition = await graph.query(.init(
            key: successorKey,
            selectedSources: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)]
        ))
        guard case .unavailable(.staleCurrentness) = staleDisposition else {
            return XCTFail("A generation-1 proof must not serve generation 3 before its successor seal.")
        }

        let removedSnapshot = snapshot(
            authority: authority,
            bindings: Array(bindings.dropLast()),
            generation: 3
        )
        let removedDisposition = await graph.applyEquivalentProjectionSuccessor(
            WorkspaceCodemapProjectionSuccessorSeal(
                predecessorProof: firstProof,
                successorProof: successorProof
            ),
            liveSnapshot: removedSnapshot
        )
        XCTAssertEqual(removedDisposition, .superseded)
        let afterRemoval = await graph.accounting()
        XCTAssertEqual(afterRemoval.publishedSummary?.key, .init(snapshot: first))

        let disposition = await graph.applyEquivalentProjectionSuccessor(
            WorkspaceCodemapProjectionSuccessorSeal(
                predecessorProof: firstProof,
                successorProof: successorProof
            ),
            liveSnapshot: successorSnapshot
        )
        guard case .accepted = disposition else {
            return XCTFail("Expected equivalent successor seal, got \(disposition).")
        }
        let result = try await requireReady(graph.query(.init(
            key: successorKey,
            selectedSources: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)]
        )))
        XCTAssertEqual(result.targets.map(\.fileID), [bindings[1].identity.fileID])
        guard case let .complete(proof, _, _, _) = result.definitionUniverseCoverage else {
            return XCTFail("Expected complete successor coverage.")
        }
        XCTAssertEqual(proof, successorProof)
        let successorAccounting = await graph.accounting()
        XCTAssertEqual(
            successorAccounting.residentProjectionByteCount,
            firstAccounting.residentProjectionByteCount
        )
        XCTAssertEqual(successorAccounting.publishedSummary?.key, successorKey)

        let duplicateSnapshot = snapshot(
            authority: authority,
            bindings: bindings + [bindings[0]],
            generation: 3
        )
        let duplicateRebuild = await graph.rebuild(from: duplicateSnapshot)
        XCTAssertEqual(
            duplicateRebuild,
            .rejected(
                .init(snapshot: duplicateSnapshot),
                .invalidSnapshot(.duplicateFileID)
            )
        )
        let duplicateSuccessor = await graph.applyEquivalentProjectionSuccessor(
            WorkspaceCodemapProjectionSuccessorSeal(
                predecessorProof: firstProof,
                successorProof: successorProof
            ),
            liveSnapshot: successorSnapshot
        )
        XCTAssertEqual(duplicateSuccessor, .superseded)
        let conflictedQuery = await graph.query(.init(
            key: successorKey,
            selectedSources: [.init(
                fileID: bindings[0].identity.fileID,
                requestGeneration: 7
            )]
        ))
        XCTAssertEqual(conflictedQuery, .unavailable(.invalidSnapshot))
    }

    func testStagedIncompleteShardWithResidentNodesReturnsNoStructureResult() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let value = snapshot(authority: authority, bindings: bindings, generation: 1)
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        try await requirePublished(graph.rebuild(from: value))
        _ = try await publishCompleteProjection(on: graph, snapshot: value, seal: false)

        let accounting = await graph.accounting()
        XCTAssertEqual(accounting.publishedSummary?.nodeCount, 2)
        guard case .incomplete? = accounting.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Expected staged incomplete coverage over resident live nodes.")
        }
        let disposition = await graph.queryStructure(.init(
            key: .init(snapshot: value),
            seeds: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)],
            direction: .both,
            limits: .init(
                maximumDepth: 2,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            )
        ))
        guard case let .definitionUniverse(.incomplete(progress, remainingCount, retry)) = disposition
        else { return XCTFail("Incomplete coverage must not return structure nodes.") }
        XCTAssertEqual(progress.counts.supportedCandidateCount, 2)
        XCTAssertEqual(remainingCount, 0)
        XCTAssertNil(retry)
    }

    func testReplacementProjectionStagingPreservesCompleteShardUntilExactSeal() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let first = snapshot(authority: authority, bindings: bindings, generation: 1)
        let replacement = snapshot(authority: authority, bindings: bindings, generation: 2)
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        try await requirePublished(graph.rebuild(from: first))
        _ = try await publishCompleteProjection(on: graph, snapshot: first)
        let firstAccounting = await graph.accounting()
        XCTAssertGreaterThan(firstAccounting.residentProjectionByteCount, 0)

        let replacementProof = try await publishCompleteProjection(
            on: graph,
            snapshot: replacement,
            seal: false
        )
        let stagedAccounting = await graph.accounting()
        XCTAssertEqual(stagedAccounting.publishedSummary?.key, .init(snapshot: first))
        XCTAssertEqual(
            stagedAccounting.residentProjectionByteCount,
            firstAccounting.residentProjectionByteCount
        )
        guard case .complete? = stagedAccounting.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Replacement staging must retain the last complete shard.")
        }

        let stagedQuery = await graph.queryStructure(.init(
            key: .init(snapshot: replacement),
            seeds: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)],
            direction: .both,
            limits: .init(
                maximumDepth: 2,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            )
        ))
        guard case .definitionUniverse(.incomplete) = stagedQuery else {
            return XCTFail("Replacement staging must expose typed incomplete coverage without old nodes.")
        }

        guard case .accepted = await graph.applyProjectionSnapshot(.seal(replacementProof)) else {
            return XCTFail("Expected the exact replacement proof to commit.")
        }
        let committedAccounting = await graph.accounting()
        XCTAssertEqual(committedAccounting.publishedSummary?.key, .init(snapshot: replacement))
        guard case .complete? = committedAccounting.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Expected the committed replacement shard to remain complete.")
        }
    }

    func testProjectionSegmentByteBudgetIsTypedAndTargetless() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let value = snapshot(authority: authority, bindings: bindings, generation: 1)
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(
                maximumProjectionSegmentByteCount: 1,
                maximumStagedProjectionByteCount: 1
            )
        )
        try await requirePublished(graph.rebuild(from: value))
        do {
            _ = try await publishCompleteProjection(on: graph, snapshot: value)
            XCTFail("Expected byte-bounded segment rejection.")
        } catch SelectionGraphTestError.projectionSegmentRejected {
            // Expected: the helper observed a typed graph rejection.
        }
        let query = WorkspaceCodemapSelectionGraphRuntimeQuery(
            key: .init(snapshot: value),
            selectedSources: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)]
        )
        guard case let .definitionUniverse(.budget(dimension, attempted, limit)) =
            await graph.query(query)
        else { return XCTFail("Expected typed projection byte budget coverage.") }
        XCTAssertEqual(dimension, .retainedProjectionBytes)
        XCTAssertGreaterThan(attempted, limit)
        XCTAssertEqual(limit, 1)
    }

    func testProjectionCoverageAndBytesAreRevokedOnPathFence() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let value = try await snapshot(
            authority: authority,
            bindings: graphBindings(authority: authority),
            generation: 1
        )
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        try await requirePublished(graph.rebuild(from: value))
        _ = try await publishCompleteProjection(on: graph, snapshot: value)
        let sealedAccounting = await graph.accounting()
        XCTAssertGreaterThan(sealedAccounting.residentProjectionByteCount, 0)

        let fenced = await graph.fenceContributionsForPathInvalidation(
            rootEpoch: authority.capability.rootEpoch
        )
        XCTAssertTrue(fenced)
        let accounting = await graph.accounting()
        XCTAssertEqual(accounting.stagedProjectionByteCount, 0)
        XCTAssertEqual(accounting.residentProjectionByteCount, 0)
        XCTAssertEqual(accounting.revokedProjectionCoverageCount, 1)
        let queryDisposition = await graph.query(.init(
            key: .init(snapshot: value),
            selectedSources: []
        ))
        XCTAssertEqual(
            queryDisposition,
            .unavailable(.notBuilt)
        )
    }

    func testProjectionSegmentSupersedesSameGenerationLiveBuildWithoutLateDowngrade() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let value = snapshot(authority: authority, bindings: bindings, generation: 1)
        let gate = SelectionGraphBuildGate()
        defer { gate.releaseAll() }
        let graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            diagnostics: gate.diagnostics
        )
        let liveBuild = Task { await graph.rebuild(from: value) }
        XCTAssertTrue(gate.waitUntilBlocked(generation: 1))

        let proof = try await publishCompleteProjection(on: graph, snapshot: value, seal: false)
        gate.releaseAll()
        let lateLiveDisposition = await liveBuild.value
        switch lateLiveDisposition {
        case .cancelled, .superseded:
            break
        case .published, .publishedEmpty, .busy, .rejected:
            XCTFail("A staged projection must supersede same-generation live publication.")
        }
        guard case .accepted = await graph.applyProjectionSnapshot(.seal(proof)) else {
            return XCTFail("Expected staged projection to seal after live cancellation.")
        }
        let result = try await requireReady(graph.query(.init(
            key: .init(snapshot: value),
            selectedSources: [.init(fileID: bindings[0].identity.fileID, requestGeneration: 7)]
        )))
        XCTAssertEqual(result.targets.map(\.fileID), [bindings[1].identity.fileID])
    }

    func testReadyPartialResolutionIsDeterministicAcrossPermutationsAndCandidateBounds() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Source.swift": "struct Source {}",
                "A.swift": "struct A {}",
                "B.swift": "struct B {}"
            ]
        )
        defer { authority.repositoryFixture.cleanup() }

        let sourceID = uuid("10000000-0000-0000-0000-000000000001")
        let aID = uuid("10000000-0000-0000-0000-000000000002")
        let bID = uuid("10000000-0000-0000-0000-000000000003")
        let sourceBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: sourceID,
            artifact: makeArtifact(definitions: [], references: ["Target", "Missing"])
        )
        let aBinding = try await makeResolvedBinding(
            authority: authority,
            path: "A.swift",
            fileID: aID,
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        let bBinding = try await makeResolvedBinding(
            authority: authority,
            path: "B.swift",
            fileID: bID,
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        let bindings = [sourceBinding, aBinding, bBinding]
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 20
        ))
        let first = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission
        )
        let second = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission
        )
        let firstSnapshot = snapshot(authority: authority, bindings: bindings, generation: 13)
        let secondSnapshot = snapshot(authority: authority, bindings: bindings.reversed(), generation: 13)
        try await requirePublished(first.rebuild(from: firstSnapshot))
        try await requirePublished(second.rebuild(from: secondSnapshot))
        _ = try await publishCompleteProjection(on: first, snapshot: firstSnapshot)
        _ = try await publishCompleteProjection(on: second, snapshot: secondSnapshot)

        let source = WorkspaceCodemapSelectionGraphRuntimeQuerySource(
            fileID: sourceID,
            requestGeneration: 7
        )
        let firstResult = try await requireReady(first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [source, source]
        )))
        let secondResult = try await requireReady(second.query(.init(
            key: .init(snapshot: secondSnapshot),
            selectedSources: [source]
        )))
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult.targets.map(\.fileID), [aID, bID])
        XCTAssertEqual(firstResult.resolutions.count, 2)
        XCTAssertEqual(firstResult.referenceFailures.map(\.failure), [.provenMissingDefinition])

        let selectedTargetResult = try await requireReady(first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [
                .init(fileID: bID, requestGeneration: 7),
                source
            ]
        )))
        let permutedSelectedTargetResult = try await requireReady(first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [
                source,
                .init(fileID: bID, requestGeneration: 7)
            ]
        )))
        XCTAssertEqual(selectedTargetResult, permutedSelectedTargetResult)
        XCTAssertEqual(selectedTargetResult.targets.map(\.fileID), [aID])
        XCTAssertEqual(selectedTargetResult.resolutions.map(\.target.fileID), [aID])
        let conflictingGenerationQuery = await first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [
                source,
                .init(fileID: sourceID, requestGeneration: 8)
            ]
        ))
        XCTAssertEqual(conflictingGenerationQuery, .unavailable(.invalidQuery))

        let overflowActor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(graphSizePolicy: graphPolicy(maxDefinitionCandidates: 1)),
            admission: admission
        )
        try await requirePublished(overflowActor.rebuild(from: firstSnapshot))
        _ = try await publishCompleteProjection(on: overflowActor, snapshot: firstSnapshot)
        let overflow = try await requireReady(overflowActor.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [source]
        )))
        XCTAssertTrue(overflow.targets.isEmpty)
        XCTAssertEqual(overflow.referenceFailures.map(\.failure).sorted(by: failurePrecedes), [
            .provenMissingDefinition,
            .candidateOverflow
        ].sorted(by: failurePrecedes))

        let duplicateSnapshot = snapshot(
            authority: authority,
            bindings: bindings + [bindings[0]],
            generation: 13
        )
        let duplicateDisposition = await first.rebuild(from: duplicateSnapshot)
        XCTAssertEqual(
            duplicateDisposition,
            .rejected(
                .init(snapshot: duplicateSnapshot),
                .invalidSnapshot(.duplicateFileID)
            )
        )
        let conflictedQuery = await first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [source]
        ))
        XCTAssertEqual(conflictedQuery, .unavailable(.invalidSnapshot))
    }

    func testStructureTraversalSupportsBoundedForwardReverseAndBothBFS() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "A.swift": "struct A {}",
                "B.swift": "struct B {}",
                "C.swift": "struct C {}"
            ]
        )
        defer { authority.repositoryFixture.cleanup() }
        let aID = uuid("18000000-0000-0000-0000-000000000001")
        let bID = uuid("18000000-0000-0000-0000-000000000002")
        let cID = uuid("18000000-0000-0000-0000-000000000003")
        let bindings = try await [
            makeResolvedBinding(
                authority: authority,
                path: "A.swift",
                fileID: aID,
                artifact: makeArtifact(definitions: ["A"], references: ["B"])
            ),
            makeResolvedBinding(
                authority: authority,
                path: "B.swift",
                fileID: bID,
                artifact: makeArtifact(definitions: ["B"], references: ["C"])
            ),
            makeResolvedBinding(
                authority: authority,
                path: "C.swift",
                fileID: cID,
                artifact: makeArtifact(definitions: ["C"], references: [])
            )
        ]
        let graph = WorkspaceCodemapSelectionGraph(rootEpoch: authority.capability.rootEpoch)
        let graphSnapshot = snapshot(authority: authority, bindings: bindings, generation: 19)
        try await requirePublished(graph.rebuild(from: graphSnapshot))
        _ = try await publishCompleteProjection(on: graph, snapshot: graphSnapshot)
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: graphSnapshot)
        let limits = WorkspaceCodemapStructureTraversalLimits(
            maximumDepth: 2,
            maximumNodeCount: 3,
            maximumEdgeCount: 4,
            maximumByteCount: 4096
        )

        guard case let .readyPartial(forward) = await graph.queryStructure(.init(
            key: key,
            seeds: [.init(fileID: aID, requestGeneration: 7)],
            direction: .referencedDefinitions,
            limits: limits
        )) else { return XCTFail("Expected forward traversal") }
        XCTAssertEqual(forward.nodes.map(\.endpoint.fileID), [aID, bID, cID])
        XCTAssertEqual(forward.nodes.map(\.depth), [0, 1, 2])
        XCTAssertEqual(forward.examinedEdgeCount, 2)
        XCTAssertTrue(forward.nodes.allSatisfy { $0.endpoint.rootEpoch == authority.capability.rootEpoch })

        guard case let .readyPartial(reverse) = await graph.queryStructure(.init(
            key: key,
            seeds: [.init(fileID: cID, requestGeneration: 7)],
            direction: .referrers,
            limits: limits
        )) else { return XCTFail("Expected reverse traversal") }
        XCTAssertEqual(reverse.nodes.map(\.endpoint.fileID), [cID, bID, aID])
        XCTAssertEqual(reverse.nodes.map(\.depth), [0, 1, 2])

        let bounded = await graph.queryStructure(.init(
            key: key,
            seeds: [.init(fileID: aID, requestGeneration: 7)],
            direction: .both,
            limits: .init(
                maximumDepth: 2,
                maximumNodeCount: 2,
                maximumEdgeCount: 4,
                maximumByteCount: 4096
            )
        ))
        guard case let .budget(prefix, .nodes) = bounded else {
            return XCTFail("Expected deterministic node budget")
        }
        XCTAssertEqual(prefix.nodes.map(\.endpoint.fileID), [aID, bID])
    }

    func testRootIsolationAndEpochReplacementCannotResolveForeignTargets() async throws {
        let rootID = uuid("20000000-0000-0000-0000-000000000001")
        let firstAuthority = try await makeAuthority(
            name: #function + "-first",
            files: ["Source.swift": "struct Source {}", "Local.swift": "struct Local {}"],
            rootID: rootID,
            rootLifetimeID: uuid("20000000-0000-0000-0000-000000000002")
        )
        let secondAuthority = try await makeAuthority(
            name: #function + "-second",
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"],
            rootID: rootID,
            rootLifetimeID: uuid("20000000-0000-0000-0000-000000000003")
        )
        defer {
            firstAuthority.repositoryFixture.cleanup()
            secondAuthority.repositoryFixture.cleanup()
        }

        let firstSourceID = uuid("20000000-0000-0000-0000-000000000010")
        let firstLocalID = uuid("20000000-0000-0000-0000-000000000011")
        let secondSourceID = uuid("20000000-0000-0000-0000-000000000020")
        let secondTargetID = uuid("20000000-0000-0000-0000-000000000021")
        let firstSource = try await makeResolvedBinding(
            authority: firstAuthority,
            path: "Source.swift",
            fileID: firstSourceID,
            artifact: makeArtifact(definitions: [], references: ["ForeignTarget"])
        )
        let firstLocal = try await makeResolvedBinding(
            authority: firstAuthority,
            path: "Local.swift",
            fileID: firstLocalID,
            artifact: makeArtifact(definitions: ["LocalTarget"], references: [])
        )
        let firstSnapshot = snapshot(
            authority: firstAuthority,
            bindings: [firstSource, firstLocal],
            generation: 1
        )
        let secondSource = try await makeResolvedBinding(
            authority: secondAuthority,
            path: "Source.swift",
            fileID: secondSourceID,
            artifact: makeArtifact(definitions: [], references: ["ForeignTarget"])
        )
        let secondTarget = try await makeResolvedBinding(
            authority: secondAuthority,
            path: "Target.swift",
            fileID: secondTargetID,
            artifact: makeArtifact(definitions: ["ForeignTarget"], references: [])
        )
        let secondSnapshot = snapshot(
            authority: secondAuthority,
            bindings: [secondSource, secondTarget],
            generation: 1
        )
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 10
        ))
        let first = WorkspaceCodemapSelectionGraph(
            rootEpoch: firstAuthority.capability.rootEpoch,
            admission: admission
        )
        let second = WorkspaceCodemapSelectionGraph(
            rootEpoch: secondAuthority.capability.rootEpoch,
            admission: admission
        )
        try await requirePublished(first.rebuild(from: firstSnapshot))
        try await requirePublished(second.rebuild(from: secondSnapshot))
        _ = try await publishCompleteProjection(on: first, snapshot: firstSnapshot)
        _ = try await publishCompleteProjection(on: second, snapshot: secondSnapshot)

        let firstResult = try await requireReady(first.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [.init(fileID: firstSourceID, requestGeneration: 7)]
        )))
        let secondResult = try await requireReady(second.query(.init(
            key: .init(snapshot: secondSnapshot),
            selectedSources: [.init(fileID: secondSourceID, requestGeneration: 7)]
        )))
        XCTAssertTrue(firstResult.targets.isEmpty)
        XCTAssertTrue(firstResult.resolutions.isEmpty)
        XCTAssertEqual(firstResult.referenceFailures.map(\.failure), [.provenMissingDefinition])
        XCTAssertEqual(secondResult.targets.map(\.fileID), [secondTargetID])
        XCTAssertFalse(firstResult.targets.contains(where: { $0.fileID == secondTargetID }))

        guard case let .readyPartial(firstStructure) = await first.queryStructure(.init(
            key: .init(snapshot: firstSnapshot),
            seeds: [.init(fileID: firstSourceID, requestGeneration: 7)],
            direction: .both,
            limits: .init(
                maximumDepth: 4,
                maximumNodeCount: 10,
                maximumEdgeCount: 20,
                maximumByteCount: 4096
            )
        )) else { return XCTFail("Expected root-local structure traversal") }
        XCTAssertFalse(firstStructure.nodes.contains { $0.endpoint.fileID == secondTargetID })
        XCTAssertTrue(firstStructure.nodes.allSatisfy {
            $0.endpoint.rootEpoch == firstAuthority.capability.rootEpoch
        })

        let foreignRebuild = await first.rebuild(from: secondSnapshot)
        XCTAssertEqual(
            foreignRebuild,
            .rejected(.init(snapshot: secondSnapshot), .rootEpochMismatch)
        )
        let invalidated = await first.invalidateCurrentness(
            rootEpoch: firstAuthority.capability.rootEpoch,
            reason: .rootUnloaded
        )
        XCTAssertTrue(invalidated)
        let unloadedQuery = await first.query(.init(key: .init(snapshot: firstSnapshot), selectedSources: []))
        XCTAssertEqual(
            unloadedQuery,
            .unavailable(.explicitRootUnavailable(.rootUnloaded))
        )
        let replacementQuery = await second.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: []
        ))
        XCTAssertEqual(
            replacementQuery,
            .unavailable(.staleCurrentness(currentKey: .init(snapshot: secondSnapshot)))
        )
    }

    func testImmediateStatusMatrixDistinguishesEmptyNotBuiltStaleBusyCancelledBudgetAndUnavailable() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Source.swift": "struct Source {}",
                "Target.swift": "struct Target {}",
                "Extra.swift": "struct Extra {}"
            ]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let snapshot1 = snapshot(authority: authority, bindings: bindings, generation: 1)
        let empty = snapshot(authority: authority, bindings: [], generation: 1)
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 4,
            maximumReservedBindingCount: 20
        ))
        let emptyActor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission
        )
        let notBuilt = await emptyActor.query(.init(key: .init(snapshot: empty), selectedSources: []))
        XCTAssertEqual(
            notBuilt,
            .unavailable(.notBuilt)
        )
        guard case .publishedEmpty = await emptyActor.rebuild(from: empty) else {
            return XCTFail("Expected a published empty shard.")
        }
        _ = try await publishCompleteProjection(on: emptyActor, snapshot: empty)
        let emptyResult = try await requireReady(emptyActor.query(.init(
            key: .init(snapshot: empty),
            selectedSources: [.init(fileID: UUID(), requestGeneration: 1)]
        )))
        XCTAssertEqual(emptyResult.sourceCoverage.map(\.state), [.missing])

        let gate = SelectionGraphBuildGate()
        defer { gate.releaseAll() }
        let actor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission,
            diagnostics: gate.diagnostics
        )
        let inFlight = Task { await actor.rebuild(from: snapshot1) }
        XCTAssertTrue(gate.waitUntilBlocked(generation: 1))
        let rebuilding = await actor.query(.init(key: .init(snapshot: snapshot1), selectedSources: []))
        XCTAssertEqual(
            rebuilding,
            .unavailable(.rebuilding)
        )
        let actorBusy = await actor.rebuild(from: snapshot1)
        XCTAssertEqual(
            actorBusy,
            .busy(.init(snapshot: snapshot1), .actorActiveRebuildLimit)
        )
        inFlight.cancel()
        gate.release(generation: 1)
        let cancelledBuild = await inFlight.value
        XCTAssertEqual(cancelledBuild, .cancelled(.init(snapshot: snapshot1)))
        XCTAssertFalse(gate.didTimeOut)
        let cancelledQuery = await actor.query(.init(key: .init(snapshot: snapshot1), selectedSources: []))
        XCTAssertEqual(
            cancelledQuery,
            .unavailable(.cancelled)
        )

        let limitedActor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumInputBindingCount: 1),
            admission: admission
        )
        let limitedRebuild = await limitedActor.rebuild(from: snapshot1)
        XCTAssertEqual(
            limitedRebuild,
            .rejected(
                .init(snapshot: snapshot1),
                .inputBindingLimit(attempted: 2, limit: 1)
            )
        )
        let limitedQuery = await limitedActor.query(.init(key: .init(snapshot: snapshot1), selectedSources: []))
        XCTAssertEqual(
            limitedQuery,
            .unavailable(.budgetExceeded)
        )

        let newer = snapshot(authority: authority, bindings: bindings, generation: 2)
        try await requirePublished(emptyActor.rebuild(from: newer))
        let staleQuery = await emptyActor.query(.init(key: .init(snapshot: empty), selectedSources: []))
        XCTAssertEqual(
            staleQuery,
            .unavailable(.staleCurrentness(currentKey: .init(snapshot: newer)))
        )
        let revoked = await emptyActor.invalidateCurrentness(
            rootEpoch: authority.capability.rootEpoch,
            reason: .authorityRevoked
        )
        XCTAssertTrue(revoked)
        let revokedQuery = await emptyActor.query(.init(key: .init(snapshot: newer), selectedSources: []))
        XCTAssertEqual(
            revokedQuery,
            .unavailable(.explicitRootUnavailable(.authorityRevoked))
        )

        let outputBounded = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumResolvedTargetCountPerQuery: 1),
            admission: admission
        )
        let duplicateTargetBindings = try await duplicateTargetGraphBindings(authority: authority)
        let duplicateTargetSnapshot = snapshot(
            authority: authority,
            bindings: duplicateTargetBindings,
            generation: 3
        )
        try await requirePublished(outputBounded.rebuild(from: duplicateTargetSnapshot))
        _ = try await publishCompleteProjection(on: outputBounded, snapshot: duplicateTargetSnapshot)
        let outputBoundedQuery = await outputBounded.query(.init(
            key: .init(snapshot: duplicateTargetSnapshot),
            selectedSources: [.init(fileID: duplicateTargetBindings[0].identity.fileID, requestGeneration: 7)]
        ))
        XCTAssertEqual(
            outputBoundedQuery,
            .unavailable(.budgetExceeded)
        )
    }

    func testQueryBudgetsBoundRawSourcesUniqueTargetsAndReferenceFailures() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Source.swift": "struct Source {}",
                "Second.swift": "struct Second {}",
                "Target.swift": "struct Target {}"
            ]
        )
        defer { authority.repositoryFixture.cleanup() }

        let firstSourceID = uuid("35000000-0000-0000-0000-000000000001")
        let secondSourceID = uuid("35000000-0000-0000-0000-000000000002")
        let targetID = uuid("35000000-0000-0000-0000-000000000003")
        let firstSource = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: firstSourceID,
            artifact: makeArtifact(definitions: [], references: ["Shared"])
        )
        let secondSource = try await makeResolvedBinding(
            authority: authority,
            path: "Second.swift",
            fileID: secondSourceID,
            artifact: makeArtifact(definitions: [], references: ["Shared"])
        )
        let target = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetID,
            artifact: makeArtifact(definitions: ["Shared"], references: [])
        )
        let sharedTargetSnapshot = snapshot(
            authority: authority,
            bindings: [firstSource, secondSource, target],
            generation: 1
        )
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 10
        ))
        let bounded = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(
                maximumSelectedSourceCountPerQuery: 2,
                maximumResolvedTargetCountPerQuery: 1
            ),
            admission: admission
        )
        try await requirePublished(bounded.rebuild(from: sharedTargetSnapshot))
        _ = try await publishCompleteProjection(on: bounded, snapshot: sharedTargetSnapshot)

        let firstQuerySource = WorkspaceCodemapSelectionGraphRuntimeQuerySource(
            fileID: firstSourceID,
            requestGeneration: 7
        )
        let secondQuerySource = WorkspaceCodemapSelectionGraphRuntimeQuerySource(
            fileID: secondSourceID,
            requestGeneration: 7
        )
        let uniqueTargetResult = try await requireReady(bounded.query(.init(
            key: .init(snapshot: sharedTargetSnapshot),
            selectedSources: [firstQuerySource, secondQuerySource]
        )))
        XCTAssertEqual(uniqueTargetResult.targets.map(\.fileID), [targetID])
        XCTAssertEqual(uniqueTargetResult.resolutions.map(\.target.fileID), [targetID, targetID])

        let duplicateAtLimit = try await requireReady(bounded.query(.init(
            key: .init(snapshot: sharedTargetSnapshot),
            selectedSources: [firstQuerySource, firstQuerySource]
        )))
        XCTAssertEqual(duplicateAtLimit.selectedSources, [firstQuerySource])
        let duplicateFlood = await bounded.query(.init(
            key: .init(snapshot: sharedTargetSnapshot),
            selectedSources: [firstQuerySource, firstQuerySource, firstQuerySource]
        ))
        XCTAssertEqual(duplicateFlood, .unavailable(.budgetExceeded))

        let failureSource = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: firstSourceID,
            artifact: makeArtifact(definitions: [], references: ["MissingA", "MissingB"])
        )
        let failureSnapshot = snapshot(
            authority: authority,
            bindings: [failureSource],
            generation: 2
        )
        let exactFailureBound = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumReferenceFailureCountPerQuery: 2),
            admission: admission
        )
        try await requirePublished(exactFailureBound.rebuild(from: failureSnapshot))
        _ = try await publishCompleteProjection(on: exactFailureBound, snapshot: failureSnapshot)
        let exactFailures = try await requireReady(exactFailureBound.query(.init(
            key: .init(snapshot: failureSnapshot),
            selectedSources: [firstQuerySource]
        )))
        XCTAssertEqual(exactFailures.referenceFailures.map(\.referencedName), ["MissingA", "MissingB"])

        let rejectedFailurePrefix = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumReferenceFailureCountPerQuery: 1),
            admission: admission
        )
        try await requirePublished(rejectedFailurePrefix.rebuild(from: failureSnapshot))
        _ = try await publishCompleteProjection(on: rejectedFailurePrefix, snapshot: failureSnapshot)
        let failureOverflow = await rejectedFailurePrefix.query(.init(
            key: .init(snapshot: failureSnapshot),
            selectedSources: [firstQuerySource]
        ))
        XCTAssertEqual(failureOverflow, .unavailable(.budgetExceeded))
    }

    func testGraphSizeBudgetsAcceptNAndRejectNPlusOneForEveryDimension() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let value = snapshot(authority: authority, bindings: bindings, generation: 1)
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 4
        ))
        let baseline = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission
        )
        try await requirePublished(baseline.rebuild(from: value))
        let baselineActorAccounting = await baseline.accounting()
        let baselineAccounting = try XCTUnwrap(baselineActorAccounting.publishedSummary?.sizeAccounting)
        let boundaries: [(WorkspaceCodemapSelectionGraphSizeDimension, UInt64)] = [
            (.nodes, baselineAccounting.nodes),
            (.postings, baselineAccounting.postings),
            (.edges, baselineAccounting.edges),
            (.bytes, baselineAccounting.bytes)
        ]

        for (dimension, attempted) in boundaries {
            XCTAssertGreaterThan(attempted, 0)
            let exact = WorkspaceCodemapSelectionGraph(
                rootEpoch: authority.capability.rootEpoch,
                policy: runtimePolicy(graphSizePolicy: graphPolicy(limit: attempted, for: dimension)),
                admission: admission
            )
            try await requirePublished(exact.rebuild(from: value))
            let exactAccounting = await exact.accounting()
            XCTAssertEqual(
                exactAccounting.publishedSummary?.sizeAccounting,
                baselineAccounting,
                "Expected exact \(dimension) boundary acceptance"
            )

            let limit = attempted - 1
            let rejected = WorkspaceCodemapSelectionGraph(
                rootEpoch: authority.capability.rootEpoch,
                policy: runtimePolicy(graphSizePolicy: graphPolicy(limit: limit, for: dimension)),
                admission: admission
            )
            let rejection = await rejected.rebuild(from: value)
            XCTAssertEqual(
                rejection,
                .rejected(
                    .init(snapshot: value),
                    .graphSize(.limitExceeded(dimension: dimension, attempted: attempted, limit: limit))
                ),
                "Expected \(dimension) N+1 rejection"
            )
            let rejectedQuery = await rejected.query(.init(key: .init(snapshot: value), selectedSources: []))
            XCTAssertEqual(rejectedQuery, .unavailable(.budgetExceeded))
        }
    }

    func testEqualGenerationAuthorityConflictFailsClosedUntilHigherGeneration() async throws {
        let rootID = uuid("36000000-0000-0000-0000-000000000001")
        let rootLifetimeID = uuid("36000000-0000-0000-0000-000000000002")
        let firstAuthority = try await makeAuthority(
            name: #function + "-first",
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"],
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
        let conflictingAuthority = try await makeAuthority(
            name: #function + "-conflict",
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"],
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
        defer {
            firstAuthority.repositoryFixture.cleanup()
            conflictingAuthority.repositoryFixture.cleanup()
        }

        let firstBindings = try await graphBindings(authority: firstAuthority)
        let conflictingBindings = try await graphBindings(authority: conflictingAuthority)
        let first = snapshot(authority: firstAuthority, bindings: firstBindings, generation: 1)
        let conflict = snapshot(authority: conflictingAuthority, bindings: conflictingBindings, generation: 1)
        let actor = WorkspaceCodemapSelectionGraph(
            rootEpoch: firstAuthority.capability.rootEpoch,
            admission: CodeMapSelectionGraphAdmission(policy: .init(
                maximumActiveReservationCount: 1,
                maximumReservedBindingCount: 4
            ))
        )
        try await requirePublished(actor.rebuild(from: first))
        let conflictDisposition = await actor.rebuild(from: conflict)
        XCTAssertEqual(
            conflictDisposition,
            .rejected(.init(snapshot: conflict), .equalGenerationAuthorityConflict)
        )
        let conflictQuery = await actor.query(.init(key: .init(snapshot: first), selectedSources: []))
        XCTAssertEqual(conflictQuery, .unavailable(.invalidSnapshot))
        let replayDisposition = await actor.rebuild(from: first)
        XCTAssertEqual(
            replayDisposition,
            .rejected(.init(snapshot: first), .equalGenerationAuthorityConflict)
        )
        let replayQuery = await actor.query(.init(key: .init(snapshot: first), selectedSources: []))
        XCTAssertEqual(replayQuery, .unavailable(.invalidSnapshot))

        let higher = snapshot(authority: firstAuthority, bindings: firstBindings, generation: 2)
        try await requirePublished(actor.rebuild(from: higher))
        _ = try await publishCompleteProjection(on: actor, snapshot: higher)
        _ = try await requireReady(actor.query(.init(key: .init(snapshot: higher), selectedSources: [])))
    }

    func testStaleSourceAndTargetGenerationsAreOmittedWithoutPartialPublication() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let sourceID = uuid("40000000-0000-0000-0000-000000000001")
        let targetID = uuid("40000000-0000-0000-0000-000000000002")
        let firstBindings = try await graphBindings(
            authority: authority,
            sourceID: sourceID,
            targetID: targetID
        )
        let firstSnapshot = snapshot(authority: authority, bindings: firstBindings, generation: 1)
        let actor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: CodeMapSelectionGraphAdmission(policy: .init(
                maximumActiveReservationCount: 1,
                maximumReservedBindingCount: 10
            ))
        )
        try await requirePublished(actor.rebuild(from: firstSnapshot))
        _ = try await publishCompleteProjection(on: actor, snapshot: firstSnapshot)
        let beforeStaleSource = await actor.accounting()
        let staleSource = await actor.query(.init(
            key: .init(snapshot: firstSnapshot),
            selectedSources: [.init(fileID: sourceID, requestGeneration: 6)]
        ))
        XCTAssertEqual(
            staleSource,
            .unavailable(.staleCurrentness(currentKey: .init(snapshot: firstSnapshot)))
        )
        let afterStaleSource = await actor.accounting()
        XCTAssertEqual(
            afterStaleSource.materializedQueryResultCount,
            beforeStaleSource.materializedQueryResultCount
        )

        let secondSource = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: sourceID,
            requestGeneration: 8,
            artifact: makeArtifact(definitions: [], references: ["Target"])
        )
        let secondTarget = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetID,
            requestGeneration: 8,
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        let secondBindings = [secondSource, secondTarget]
        let secondSnapshot = snapshot(authority: authority, bindings: secondBindings, generation: 2)
        try await requirePublished(actor.rebuild(from: secondSnapshot))
        _ = try await publishCompleteProjection(on: actor, snapshot: secondSnapshot)
        let current = try await requireReady(actor.query(.init(
            key: .init(snapshot: secondSnapshot),
            selectedSources: [.init(fileID: sourceID, requestGeneration: 8)]
        )))
        XCTAssertEqual(current.targets.map(\.requestGeneration), [8])
        XCTAssertFalse(current.targets.contains(where: { $0.requestGeneration == 7 }))
        XCTAssertTrue(current.resolutions.allSatisfy {
            $0.source.requestGeneration == 8 && $0.target.requestGeneration == 8
        })
        guard case .complete = current.definitionUniverseCoverage else {
            return XCTFail("Expected current generations to retain complete publishable coverage.")
        }

        let pending = try await makePendingBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetID,
            requestGeneration: 9
        )
        let rejectedSnapshot = snapshot(
            authority: authority,
            bindings: [secondBindings[0], pending],
            generation: 3
        )
        let rejectedBuild = await actor.rebuild(from: rejectedSnapshot)
        XCTAssertEqual(
            rejectedBuild,
            .rejected(.init(snapshot: rejectedSnapshot), .invalidSnapshot(.bindingNotResolved))
        )
        let accounting = await actor.accounting()
        XCTAssertEqual(accounting.currentObservedKey, .init(snapshot: rejectedSnapshot))
        XCTAssertEqual(accounting.publishedSummary?.key, .init(snapshot: secondSnapshot))
        guard case .complete? = accounting.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Rejected replacement must retain the prior complete shard.")
        }
        let rejectedQuery = await actor.query(.init(
            key: .init(snapshot: rejectedSnapshot),
            selectedSources: []
        ))
        XCTAssertEqual(
            rejectedQuery,
            .unavailable(.invalidSnapshot)
        )
        let priorQuery = await actor.query(.init(
            key: .init(snapshot: secondSnapshot),
            selectedSources: [.init(fileID: sourceID, requestGeneration: 8)]
        ))
        XCTAssertEqual(
            priorQuery,
            .unavailable(.staleCurrentness(currentKey: .init(snapshot: rejectedSnapshot)))
        )
    }

    func testActorAndProcessAdmissionAreExactRecoverableAndReleaseOnce() async throws {
        let direct = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 2
        ))
        let concurrentPermit = try direct.reserve(bindingCount: 2)
        XCTAssertEqual(direct.accounting().activeReservationCount, 1)
        XCTAssertThrowsError(try direct.reserve(bindingCount: 0)) {
            XCTAssertEqual($0 as? CodeMapSelectionGraphAdmissionError, .busy(.activeReservationCountLimit))
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { concurrentPermit.close() }
            }
        }
        concurrentPermit.close()
        XCTAssertEqual(direct.accounting().reservedBindingCount, 0)
        var deinitPermit: CodeMapSelectionGraphAdmissionPermit? = try direct.reserve(bindingCount: 1)
        XCTAssertNotNil(deinitPermit)
        deinitPermit = nil
        XCTAssertEqual(direct.accounting().activeReservationCount, 0)
        XCTAssertFalse(direct.accounting().hasFailedClosed)

        let bindingBounded = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 2
        ))
        let bindingPermit = try bindingBounded.reserve(bindingCount: 1)
        XCTAssertThrowsError(try bindingBounded.reserve(bindingCount: 2)) {
            XCTAssertEqual($0 as? CodeMapSelectionGraphAdmissionError, .busy(.reservedBindingCountLimit))
        }
        bindingPermit.close()
        XCTAssertEqual(bindingBounded.accounting().reservedBindingCount, 0)

        let failedClosed = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 1
        ))
        XCTAssertThrowsError(try failedClosed.reserve(bindingCount: -1)) {
            XCTAssertEqual($0 as? CodeMapSelectionGraphAdmissionError, .accountingOverflow)
        }
        XCTAssertTrue(failedClosed.accounting().hasFailedClosed)
        XCTAssertThrowsError(try failedClosed.reserve(bindingCount: 0)) {
            XCTAssertEqual($0 as? CodeMapSelectionGraphAdmissionError, .accountingOverflow)
        }

        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let value = try await snapshot(
            authority: authority,
            bindings: graphBindings(authority: authority),
            generation: 1
        )

        let localAdmission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 4
        ))
        let localGate = SelectionGraphBuildGate()
        defer { localGate.releaseAll() }
        let local = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(
                maximumActiveRebuildCount: 2,
                maximumReservedBindingCount: 2
            ),
            admission: localAdmission,
            diagnostics: localGate.diagnostics
        )
        let localTask = Task { await local.rebuild(from: value) }
        guard localGate.waitUntilBlocked(generation: 1) else {
            localTask.cancel()
            localGate.release(generation: 1)
            return XCTFail("Actor-local exact-bound rebuild did not reach the gate.")
        }
        let localExactAccounting = await local.accounting()
        XCTAssertEqual(localExactAccounting.reservedInputBindingCount, 2)
        let localBusy = await local.rebuild(from: value)
        XCTAssertEqual(
            localBusy,
            .busy(.init(snapshot: value), .actorReservedBindingLimit)
        )
        localTask.cancel()
        localGate.release(generation: 1)
        let localCancelled = await localTask.value
        XCTAssertEqual(localCancelled, .cancelled(.init(snapshot: value)))
        let localReleasedAccounting = await local.accounting()
        XCTAssertEqual(localReleasedAccounting.reservedInputBindingCount, 0)
        XCTAssertEqual(localAdmission.accounting().reservedBindingCount, 0)
        XCTAssertFalse(localGate.didTimeOut)

        let shared = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 2
        ))
        let sharedGate = SelectionGraphBuildGate()
        defer { sharedGate.releaseAll() }
        let first = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: shared,
            diagnostics: sharedGate.diagnostics
        )
        let second = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: shared
        )
        let task = Task { await first.rebuild(from: value) }
        guard sharedGate.waitUntilBlocked(generation: 1) else {
            task.cancel()
            sharedGate.release(generation: 1)
            return XCTFail("Shared exact-bound rebuild did not reach the gate.")
        }
        XCTAssertEqual(shared.accounting().reservedBindingCount, 2)
        let processBusy = await second.rebuild(from: value)
        XCTAssertEqual(
            processBusy,
            .busy(.init(snapshot: value), .processAdmission(.reservedBindingCountLimit))
        )
        let processBusyQuery = await second.query(.init(
            key: .init(snapshot: value),
            selectedSources: []
        ))
        XCTAssertEqual(
            processBusyQuery,
            .unavailable(.processAdmissionRejected(.reservedBindingCountLimit))
        )
        let invalidated = await first.invalidateCurrentness(
            rootEpoch: authority.capability.rootEpoch,
            reason: .authorityRevoked
        )
        XCTAssertTrue(invalidated)
        sharedGate.release(generation: 1)
        let invalidatedBuild = await task.value
        XCTAssertEqual(invalidatedBuild, .cancelled(.init(snapshot: value)))
        XCTAssertEqual(shared.accounting().activeReservationCount, 0)
        XCTAssertEqual(shared.accounting().reservedBindingCount, 0)
        let invalidatedQuery = await first.query(.init(
            key: .init(snapshot: value),
            selectedSources: []
        ))
        XCTAssertEqual(
            invalidatedQuery,
            .unavailable(.explicitRootUnavailable(.authorityRevoked))
        )
        try await requirePublished(second.rebuild(from: value))
        XCTAssertEqual(shared.accounting().activeReservationCount, 0)
        XCTAssertEqual(shared.accounting().reservedBindingCount, 0)
        XCTAssertFalse(sharedGate.didTimeOut)
    }

    func testCrossActorProcessActiveReservationLimitSaturatesAndRecovers() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let value = try await snapshot(
            authority: authority,
            bindings: graphBindings(authority: authority),
            generation: 1
        )
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 4
        ))
        let gate = SelectionGraphBuildGate()
        defer { gate.releaseAll() }
        let first = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission,
            diagnostics: gate.diagnostics
        )
        let second = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            admission: admission
        )

        let firstTask = Task { await first.rebuild(from: value) }
        guard gate.waitUntilBlocked(generation: 1) else {
            firstTask.cancel()
            gate.releaseAll()
            _ = await firstTask.value
            return XCTFail("First actor did not reach the process admission gate.")
        }
        XCTAssertEqual(admission.accounting().activeReservationCount, 1)
        XCTAssertEqual(admission.accounting().reservedBindingCount, 2)
        let processBusy = await second.rebuild(from: value)
        XCTAssertEqual(
            processBusy,
            .busy(.init(snapshot: value), .processAdmission(.activeReservationCountLimit))
        )
        let processBusyQuery = await second.query(.init(key: .init(snapshot: value), selectedSources: []))
        XCTAssertEqual(
            processBusyQuery,
            .unavailable(.processAdmissionRejected(.activeReservationCountLimit))
        )

        gate.release(generation: 1)
        try await requirePublished(firstTask.value)
        XCTAssertEqual(admission.accounting().activeReservationCount, 0)
        XCTAssertEqual(admission.accounting().reservedBindingCount, 0)
        try await requirePublished(second.rebuild(from: value))
        XCTAssertEqual(admission.accounting().activeReservationCount, 0)
        XCTAssertEqual(admission.accounting().reservedBindingCount, 0)
        XCTAssertFalse(gate.didTimeOut)
    }

    func testRejectedCancelledAndSupersededBuildsPreserveTheLastCompleteShard() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        defer { authority.repositoryFixture.cleanup() }
        let bindings = try await graphBindings(authority: authority)
        let base = snapshot(authority: authority, bindings: bindings, generation: 1)
        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 2,
            maximumReservedBindingCount: 10
        ))
        let baseActor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumActiveRebuildCount: 2),
            admission: admission
        )
        try await requirePublished(baseActor.rebuild(from: base))

        let gate = SelectionGraphBuildGate()
        defer { gate.releaseAll() }
        let actor = WorkspaceCodemapSelectionGraph(
            rootEpoch: authority.capability.rootEpoch,
            policy: runtimePolicy(maximumActiveRebuildCount: 2),
            admission: admission,
            diagnostics: gate.diagnostics
        )
        let baseTask = Task { await actor.rebuild(from: base) }
        XCTAssertTrue(gate.waitUntilBlocked(generation: 1))
        gate.release(generation: 1)
        try await requirePublished(baseTask.value)
        let second = snapshot(authority: authority, bindings: bindings, generation: 2)
        let third = snapshot(authority: authority, bindings: bindings, generation: 3)
        let secondTask = Task { await actor.rebuild(from: second) }
        guard gate.waitUntilBlocked(generation: 2) else {
            secondTask.cancel()
            gate.release(generation: 2)
            return XCTFail("Second rebuild did not reach the publication gate.")
        }
        let thirdTask = Task { await actor.rebuild(from: third) }
        guard gate.waitUntilBlocked(generation: 3) else {
            secondTask.cancel()
            thirdTask.cancel()
            gate.release(generation: 2)
            gate.release(generation: 3)
            return XCTFail("Third rebuild did not reach the publication gate.")
        }
        gate.release(generation: 3)
        try await requirePublished(thirdTask.value)
        let thirdProof = try await publishCompleteProjection(on: actor, snapshot: third, seal: false)
        let thirdSealTask = Task { await actor.applyProjectionSnapshot(.seal(thirdProof)) }
        guard gate.waitUntilBlocked(generation: 3) else {
            thirdSealTask.cancel()
            gate.release(generation: 3)
            return XCTFail("Third projection seal did not reach the publication gate.")
        }
        gate.release(generation: 3)
        guard case .accepted = await thirdSealTask.value else {
            return XCTFail("Expected the third projection to seal exactly.")
        }
        let afterLatestPublication = await actor.accounting()
        XCTAssertEqual(afterLatestPublication.publishedSummary?.key, .init(snapshot: third))
        guard case .complete? = afterLatestPublication.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Expected the retained third shard to have exact complete coverage.")
        }

        gate.release(generation: 2)
        let superseded = await secondTask.value
        XCTAssertEqual(superseded, .superseded(.init(snapshot: second)))
        let afterSupersededCompletion = await actor.accounting()
        XCTAssertEqual(afterSupersededCompletion.publishedSummary?.key, .init(snapshot: third))
        XCTAssertEqual(
            afterSupersededCompletion.publishedCount,
            afterLatestPublication.publishedCount
        )

        let fourth = snapshot(authority: authority, bindings: bindings, generation: 4)
        let cancelledTask = Task { await actor.rebuild(from: fourth) }
        XCTAssertTrue(gate.waitUntilBlocked(generation: 4))
        let duringReplacement = await actor.accounting()
        XCTAssertEqual(duringReplacement.publishedSummary?.key, .init(snapshot: third))
        cancelledTask.cancel()
        gate.release(generation: 4)
        let cancelled = await cancelledTask.value
        XCTAssertEqual(cancelled, .cancelled(.init(snapshot: fourth)))
        let afterCancellation = await actor.accounting()
        XCTAssertEqual(afterCancellation.publishedSummary?.key, .init(snapshot: third))
        guard case .complete? = afterCancellation.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Cancellation must retain the last complete shard.")
        }
        let cancelledQuery = await actor.query(.init(key: .init(snapshot: fourth), selectedSources: []))
        XCTAssertEqual(
            cancelledQuery,
            .unavailable(.cancelled)
        )

        let pending = try await makePendingBinding(
            authority: authority,
            path: "Target.swift",
            fileID: bindings[1].identity.fileID,
            requestGeneration: 9
        )
        let fifth = snapshot(authority: authority, bindings: [bindings[0], pending], generation: 5)
        let rejected = await actor.rebuild(from: fifth)
        XCTAssertEqual(
            rejected,
            .rejected(.init(snapshot: fifth), .invalidSnapshot(.bindingNotResolved))
        )
        let afterRejection = await actor.accounting()
        XCTAssertEqual(afterRejection.publishedSummary?.key, .init(snapshot: third))
        guard case .complete? = afterRejection.publishedSummary?.definitionUniverseCoverage else {
            return XCTFail("Rejection must retain the last complete shard.")
        }
        XCTAssertFalse(gate.didTimeOut)
    }

    func testValueOnlyBoundaryNeedsNoProducerOrIOAfterSnapshotCapture() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: ["Source.swift": "struct Source {}", "Target.swift": "struct Target {}"]
        )
        let sourceID = uuid("70000000-0000-0000-0000-000000000001")
        let targetID = uuid("70000000-0000-0000-0000-000000000002")
        let value = try await snapshot(
            authority: authority,
            bindings: graphBindings(
                authority: authority,
                sourceID: sourceID,
                targetID: targetID
            ),
            generation: 1
        )
        let rootEpoch = authority.capability.rootEpoch
        authority.repositoryFixture.cleanup()

        let admission = CodeMapSelectionGraphAdmission(policy: .init(
            maximumActiveReservationCount: 1,
            maximumReservedBindingCount: 2
        ))
        let actor = WorkspaceCodemapSelectionGraph(
            rootEpoch: rootEpoch,
            policy: runtimePolicy(),
            admission: admission,
            diagnostics: .none
        )
        try await requirePublished(actor.rebuild(from: value))
        _ = try await publishCompleteProjection(on: actor, snapshot: value)
        let result = try await requireReady(actor.query(.init(
            key: .init(snapshot: value),
            selectedSources: [.init(fileID: sourceID, requestGeneration: 7)]
        )))
        XCTAssertEqual(result.targets.map(\.fileID), [targetID])
        XCTAssertEqual(result.targets.map(\.rootEpoch), [rootEpoch])
        requireSendable(WorkspaceCodemapSelectionGraphRuntimeKey.self)
        requireSendable(WorkspaceCodemapSelectionGraphRuntimeQueryDisposition.self)
        requireSendable(CodeMapSelectionGraphAdmissionPermit.self)
    }

    private func makeAuthority(
        name: String,
        files: [String: String],
        rootID: UUID = UUID(),
        rootLifetimeID: UUID = UUID()
    ) async throws -> WorkspaceCodemapAuthorityTestFixture {
        try await WorkspaceCodemapAuthorityTestFixture.make(
            name: name,
            files: files,
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
    }

    private func makeResolvedBinding(
        authority: WorkspaceCodemapAuthorityTestFixture,
        path: String,
        fileID: UUID,
        requestGeneration: UInt64 = 7,
        artifact: CodeMapSyntaxArtifact
    ) async throws -> WorkspaceCodemapArtifactBinding {
        let source = try await authority.validatedWorktreeSource(loadedRootRelativePath: path)
        let identity = try authority.bindingIdentity(fileID: fileID, loadedRootRelativePath: path)
        let sourceAuthority = try await authority.sourceAuthority(repositoryRelativePath: path)
        let pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: source.decoderPolicy)
        let artifactKey = try CodeMapArtifactKey(source: source, pipelineIdentity: pipeline)
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: artifactKey,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: 11,
            sourceExpectation: expectation
        ))
        let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: token,
            language: .swift,
            outcome: .ready(artifact)
        ))
        var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: token))
        XCTAssertEqual(binding.apply(completion), .accepted)
        return binding
    }

    private func makePendingBinding(
        authority: WorkspaceCodemapAuthorityTestFixture,
        path: String,
        fileID: UUID,
        requestGeneration: UInt64
    ) async throws -> WorkspaceCodemapArtifactBinding {
        let source = try await authority.validatedWorktreeSource(loadedRootRelativePath: path)
        let identity = try authority.bindingIdentity(fileID: fileID, loadedRootRelativePath: path)
        let sourceAuthority = try await authority.sourceAuthority(repositoryRelativePath: path)
        let pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: source.decoderPolicy)
        let artifactKey = try CodeMapArtifactKey(source: source, pipelineIdentity: pipeline)
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: artifactKey,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: 11,
            sourceExpectation: expectation
        ))
        return try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: token))
    }

    private func graphBindings(
        authority: WorkspaceCodemapAuthorityTestFixture,
        sourceID: UUID = UUID(),
        targetID: UUID = UUID()
    ) async throws -> [WorkspaceCodemapArtifactBinding] {
        let source = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: sourceID,
            artifact: makeArtifact(definitions: [], references: ["Target"])
        )
        let target = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetID,
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        return [source, target]
    }

    private func duplicateTargetGraphBindings(
        authority: WorkspaceCodemapAuthorityTestFixture
    ) async throws -> [WorkspaceCodemapArtifactBinding] {
        let extraPath = "Extra.swift"
        let source = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: UUID(),
            artifact: makeArtifact(definitions: [], references: ["Target"])
        )
        let target = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: UUID(),
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        let extra = try await makeResolvedBinding(
            authority: authority,
            path: extraPath,
            fileID: UUID(),
            artifact: makeArtifact(definitions: ["Target"], references: [])
        )
        return [source, target, extra]
    }

    private func snapshot(
        authority: WorkspaceCodemapAuthorityTestFixture,
        bindings: some Sequence<WorkspaceCodemapArtifactBinding>,
        generation: UInt64
    ) -> WorkspaceCodemapLiveGraphSnapshot {
        WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: authority.capability.rootEpoch,
            catalogGeneration: 11,
            repositoryAuthority: authority.capability.repositoryAuthority,
            contributionGeneration: .init(rawValue: generation),
            bindings: Array(bindings)
        )
    }

    private func makeArtifact(definitions: [String], references: [String]) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }

    @discardableResult
    private func publishCompleteProjection(
        on graph: WorkspaceCodemapSelectionGraph,
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        seal: Bool = true
    ) async throws -> WorkspaceCodemapProjectionCoverageProof {
        let token = WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: snapshot.rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: snapshot.catalogGeneration,
            ingressGeneration: snapshot.catalogGeneration,
            projectionInvalidationGeneration: 1
        )
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: token,
            repositoryAuthority: snapshot.repositoryAuthority,
            contributionGeneration: snapshot.contributionGeneration
        )
        let entries = try snapshot.bindings.map { binding -> WorkspaceCodemapProjectionEntry in
            guard case let .resolved(completion) = binding.availability else {
                throw SelectionGraphTestError.invalidProjectionBinding
            }
            let outcome: WorkspaceCodemapProjectionEntryOutcome = switch completion.outcome {
            case let .ready(artifact):
                .contributed(CodeMapSelectionGraphContribution(
                    artifactKey: completion.artifactKey,
                    artifact: artifact
                ))
            case .readyNoSymbols:
                .empty(CodeMapSelectionGraphContribution(
                    artifactKey: completion.artifactKey,
                    definitions: [] as [String],
                    references: [] as [String]
                ))
            case .oversize, .decodeFailed, .parseFailed:
                throw SelectionGraphTestError.invalidProjectionBinding
            }
            return WorkspaceCodemapProjectionEntry(
                identity: binding.identity,
                requestGeneration: completion.token.requestGeneration,
                pathGeneration: completion.token.requestGeneration,
                pipelineIdentity: completion.artifactKey.pipelineIdentity,
                outcome: outcome
            )
        }.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return $0.identity.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                    $1.identity.standardizedRelativePath.utf8
                )
            }
            return $0.identity.fileID.uuidString < $1.identity.fileID.uuidString
        }
        let contributedCount = UInt64(entries.count(where: {
            if case .contributed = $0.outcome { return true }
            return false
        }))
        let emptyCount = UInt64(entries.count) - contributedCount
        let counts = WorkspaceCodemapProjectionCounts(
            supportedCandidateCount: UInt64(entries.count),
            processedCandidateCount: UInt64(entries.count),
            contributedCount: contributedCount,
            emptyCount: emptyCount,
            terminalArtifactCount: 0,
            terminalExcludedCount: 0,
            transientCount: 0
        )
        let completion = WorkspaceCodemapProjectionCatalogCompletion(
            token: token,
            finalCursor: entries.last.map {
                WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: $0.identity.standardizedRelativePath,
                    fileID: $0.identity.fileID
                )
            },
            supportedCandidateCount: UInt64(entries.count)
        )

        let lastSegmentSequence: UInt64?
        if entries.isEmpty {
            lastSegmentSequence = nil
        } else {
            let byteCount: UInt64
            switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
                entries: entries
            ) {
            case let .success(value):
                byteCount = value
            case .failure:
                throw SelectionGraphTestError.invalidProjectionAccounting
            }
            let progress = WorkspaceCodemapProjectionProgress(
                phase: .publishingProjectionSegment,
                counts: counts,
                catalogPageCount: 1,
                catalogPathByteCount: UInt64(entries.reduce(0) {
                    $0 + $1.identity.standardizedRelativePath.utf8.count
                }),
                publishedSegmentCount: 1,
                publishedSegmentByteCount: byteCount,
                catalogCompletion: completion
            )
            let segment: WorkspaceCodemapProjectionSegment
            switch WorkspaceCodemapProjectionSegment.validated(
                generation: generation,
                sequence: 0,
                entries: entries,
                progress: progress,
                byteCount: byteCount
            ) {
            case let .success(value):
                segment = value
            case .failure:
                throw SelectionGraphTestError.invalidProjectionSegment
            }
            let segmentDisposition = await graph.applyProjectionSnapshot(.segment(segment))
            switch segmentDisposition {
            case .accepted, .exactDuplicate:
                break
            case .stale, .superseded, .busy, .budget, .unavailable:
                throw SelectionGraphTestError.projectionSegmentRejected
            }
            lastSegmentSequence = 0
        }

        let proof: WorkspaceCodemapProjectionCoverageProof
        switch WorkspaceCodemapProjectionCoverageProof.validated(
            generation: generation,
            catalogCompletion: completion,
            counts: counts,
            lastSegmentSequence: lastSegmentSequence
        ) {
        case let .success(value):
            proof = value
        case .failure:
            throw SelectionGraphTestError.invalidProjectionProof
        }
        if seal {
            let sealDisposition = await graph.applyProjectionSnapshot(.seal(proof))
            switch sealDisposition {
            case .accepted, .exactDuplicate:
                break
            case .stale, .superseded, .busy, .budget, .unavailable:
                throw SelectionGraphTestError.projectionSealRejected
            }
        }
        return proof
    }

    private func runtimePolicy(
        maximumActiveRebuildCount: Int = 1,
        maximumReservedBindingCount: Int = 100,
        maximumInputBindingCount: Int = 100,
        maximumSelectedSourceCountPerQuery: Int = 100,
        maximumResolvedTargetCountPerQuery: Int = 100,
        maximumReferenceFailureCountPerQuery: Int = 100,
        graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy? = nil,
        maximumProjectionSegmentByteCount: UInt64 = 8 * 1024 * 1024,
        maximumStagedProjectionByteCount: UInt64 = 32 * 1024 * 1024
    ) -> WorkspaceCodemapSelectionGraphRuntimePolicy {
        .init(
            maximumActiveRebuildCount: maximumActiveRebuildCount,
            maximumReservedBindingCount: maximumReservedBindingCount,
            maximumInputBindingCount: maximumInputBindingCount,
            maximumSelectedSourceCountPerQuery: maximumSelectedSourceCountPerQuery,
            maximumResolvedTargetCountPerQuery: maximumResolvedTargetCountPerQuery,
            maximumReferenceFailureCountPerQuery: maximumReferenceFailureCountPerQuery,
            graphSizePolicy: graphSizePolicy ?? graphPolicy(),
            maximumProjectionSegmentByteCount: maximumProjectionSegmentByteCount,
            maximumStagedProjectionByteCount: maximumStagedProjectionByteCount
        )
    }

    private func graphPolicy(
        maxNodes: UInt64 = 100,
        maxPostings: UInt64 = 100,
        maxEdges: UInt64 = 100,
        maxBytes: UInt64 = 1_000_000,
        maxDefinitionCandidates: UInt64 = 100
    ) -> WorkspaceCodemapSelectionGraphSizePolicy {
        .init(
            maxNodes: maxNodes,
            maxPostings: maxPostings,
            maxEdges: maxEdges,
            maxBytes: maxBytes,
            maxDefinitionCandidates: maxDefinitionCandidates
        )
    }

    private func graphPolicy(
        limit: UInt64,
        for dimension: WorkspaceCodemapSelectionGraphSizeDimension
    ) -> WorkspaceCodemapSelectionGraphSizePolicy {
        switch dimension {
        case .nodes:
            graphPolicy(maxNodes: limit)
        case .postings:
            graphPolicy(maxPostings: limit)
        case .edges:
            graphPolicy(maxEdges: limit)
        case .bytes:
            graphPolicy(maxBytes: limit)
        }
    }

    private func requirePublished(
        _ disposition: WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition
    ) throws {
        guard case .published = disposition else {
            throw SelectionGraphTestError.expectedPublished(disposition)
        }
    }

    private func requireReady(
        _ disposition: WorkspaceCodemapSelectionGraphRuntimeQueryDisposition
    ) throws -> WorkspaceCodemapSelectionGraphRuntimeQueryResult {
        guard case let .readyPartial(result) = disposition else {
            throw SelectionGraphTestError.expectedReady(disposition)
        }
        return result
    }

    private func failurePrecedes(
        _ lhs: WorkspaceCodemapSelectionGraphReferenceFailure,
        _ rhs: WorkspaceCodemapSelectionGraphReferenceFailure
    ) -> Bool {
        String(describing: lhs) < String(describing: rhs)
    }

    private func requireSendable(_: (some Sendable).Type) {}

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private final class SelectionGraphBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waitingByGeneration: [UInt64: Int] = [:]
    private var releaseCountByGeneration: [UInt64: Int] = [:]
    private var timedOutGenerations = Set<UInt64>()
    private var isOpen = false

    var didTimeOut: Bool {
        condition.withLock { !timedOutGenerations.isEmpty }
    }

    var diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
        WorkspaceCodemapSelectionGraphRuntimeDiagnostics { [self] event in
            guard event.kind == .beforePublication else { return }
            block(generation: event.key.contributionGeneration.rawValue)
        }
    }

    func waitUntilBlocked(generation: UInt64, count: Int = 1) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while waitingByGeneration[generation, default: 0] < count {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release(generation: UInt64, count: Int = 1) {
        condition.lock()
        releaseCountByGeneration[generation, default: 0] += count
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func block(generation: UInt64) {
        condition.lock()
        guard !isOpen else {
            condition.unlock()
            return
        }
        waitingByGeneration[generation, default: 0] += 1
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 5)
        while !isOpen, releaseCountByGeneration[generation, default: 0] == 0 {
            guard condition.wait(until: deadline) else {
                timedOutGenerations.insert(generation)
                break
            }
        }
        if releaseCountByGeneration[generation, default: 0] > 0 {
            releaseCountByGeneration[generation, default: 0] -= 1
        }
        waitingByGeneration[generation, default: 0] -= 1
        condition.broadcast()
        condition.unlock()
    }
}

private enum SelectionGraphTestError: Error {
    case expectedPublished(WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition)
    case expectedReady(WorkspaceCodemapSelectionGraphRuntimeQueryDisposition)
    case invalidProjectionBinding
    case invalidProjectionAccounting
    case invalidProjectionSegment
    case invalidProjectionProof
    case projectionSegmentRejected
    case projectionSealRejected
}
