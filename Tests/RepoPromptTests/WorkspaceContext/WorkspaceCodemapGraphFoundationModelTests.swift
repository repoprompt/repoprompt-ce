import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class WorkspaceCodemapGraphFoundationModelTests: XCTestCase {
    func testExtractedCatalogPageValidationPreservesCanonicalCursorContract() throws {
        let rootEpoch = makeRootEpoch(seed: 1)
        let token = makeCatalogToken(rootEpoch: rootEpoch)
        let alpha = try makeCatalogCandidate(
            rootEpoch: rootEpoch,
            fileID: uuid("00000000-0000-0000-0000-000000000001"),
            path: "Sources/Alpha.swift"
        )
        let zeta = try makeCatalogCandidate(
            rootEpoch: rootEpoch,
            fileID: uuid("00000000-0000-0000-0000-000000000002"),
            path: "Sources/Zeta.swift"
        )
        let request = WorkspaceCodemapGraphIndexCatalogPageRequest(
            rootEpoch: rootEpoch,
            token: nil,
            cursor: nil,
            maximumEntryCount: 2,
            maximumPathByteCount: 1024
        )
        let endCursor = WorkspaceCodemapGraphIndexCatalogCursor(
            standardizedRelativePath: zeta.identity.standardizedRelativePath,
            fileID: zeta.identity.fileID
        )

        let page = try WorkspaceCodemapGraphIndexCatalogPage.validated(
            request: request,
            token: token,
            entries: [alpha, zeta],
            nextCursor: endCursor,
            isEnd: false,
            supportedCandidateCountThroughPage: 2
        ).get()
        XCTAssertEqual(page.nextCursor, endCursor)
        XCTAssertEqual(
            page.pathByteCount,
            UInt64(alpha.identity.standardizedRelativePath.utf8.count + zeta.identity.standardizedRelativePath.utf8.count)
        )

        XCTAssertEqual(
            WorkspaceCodemapGraphIndexCatalogPage.validated(
                request: request,
                token: token,
                entries: [zeta, alpha],
                nextCursor: nil,
                isEnd: true,
                supportedCandidateCountThroughPage: 2
            ),
            .failure(.nonCanonicalOrder)
        )
        XCTAssertEqual(
            WorkspaceCodemapGraphIndexCatalogPage.validated(
                request: request,
                token: token,
                entries: [alpha, alpha],
                nextCursor: nil,
                isEnd: true,
                supportedCandidateCountThroughPage: 2
            ),
            .failure(.duplicateFileID(alpha.identity.fileID))
        )
    }

    func testGraphSlotValidationBindsRootPipelineStateAndDiagnosticDigest() throws {
        let rootEpoch = makeRootEpoch(seed: 2)
        let pipeline = try makePipeline()
        let identity = try makeIdentity(
            rootEpoch: rootEpoch,
            fileID: uuid("00000000-0000-0000-0000-000000000010"),
            path: "Sources/Value.swift"
        )
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: makeArtifactKey(pipeline: pipeline, seed: 3),
            definitions: ["Value"],
            references: ["Dependency"]
        )
        let diagnostics = WorkspaceCodemapGraphSlotDiagnostics(
            contributionDigest: contribution.contributionDigest,
            source: .graphIndex
        )

        let slot = try WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: identity,
            requestGeneration: 7,
            pathGeneration: 9,
            pipelineIdentity: pipeline,
            state: .contributed(contribution),
            diagnostics: diagnostics
        ).get()
        XCTAssertEqual(slot.fileID, identity.fileID)
        XCTAssertEqual(slot.standardizedRelativePath, "Sources/Value.swift")
        XCTAssertEqual(slot.diagnostics, diagnostics)

        let foreignRoot = makeRootEpoch(seed: 4)
        XCTAssertEqual(
            WorkspaceCodemapGraphSlot.validated(
                rootEpoch: foreignRoot,
                identity: identity,
                requestGeneration: 7,
                pathGeneration: 9,
                pipelineIdentity: pipeline,
                state: .pending
            ),
            .failure(.rootMismatch)
        )
        XCTAssertEqual(
            WorkspaceCodemapGraphSlot.validated(
                rootEpoch: rootEpoch,
                identity: identity,
                requestGeneration: 7,
                pathGeneration: 9,
                pipelineIdentity: pipeline,
                state: .empty(contribution)
            ),
            .failure(.emptyWithNames)
        )
    }

    func testCatalogCoverageAllowsPartialQueriesButCompleteRequiresNoPendingSlots() throws {
        let rootEpoch = makeRootEpoch(seed: 5)
        let watermark = makeCatalogToken(rootEpoch: rootEpoch)
        let partial = try WorkspaceCodemapGraphCatalogCoverage.validated(
            rootEpoch: rootEpoch,
            catalogWatermark: watermark,
            enumerationState: .partial,
            supportedCount: 3,
            classifiedCount: 2,
            pendingCount: 1,
            contributedCount: 1,
            emptyCount: 0,
            terminalArtifactCount: 1,
            terminalExcludedCount: 0
        ).get()
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.terminalCount, 1)

        XCTAssertEqual(
            WorkspaceCodemapGraphCatalogCoverage.validated(
                rootEpoch: rootEpoch,
                catalogWatermark: watermark,
                enumerationState: .complete,
                supportedCount: 3,
                classifiedCount: 2,
                pendingCount: 1,
                contributedCount: 1,
                emptyCount: 0,
                terminalArtifactCount: 1,
                terminalExcludedCount: 0
            ),
            .failure(.completeWithPendingSupportedSlots(1))
        )
        let complete = try WorkspaceCodemapGraphCatalogCoverage.validated(
            rootEpoch: rootEpoch,
            catalogWatermark: watermark,
            enumerationState: .complete,
            supportedCount: 2,
            classifiedCount: 2,
            pendingCount: 0,
            contributedCount: 1,
            emptyCount: 0,
            terminalArtifactCount: 1,
            terminalExcludedCount: 0
        ).get()
        XCTAssertTrue(complete.isComplete)
    }

    func testCheckpointValidatesCoverageAndCanonicalizesSlotOrder() throws {
        let rootEpoch = makeRootEpoch(seed: 6)
        let pipeline = try makePipeline()
        let zeta = try makePendingSlot(
            rootEpoch: rootEpoch,
            fileID: uuid("00000000-0000-0000-0000-000000000021"),
            path: "Sources/Zeta.swift",
            pipeline: pipeline
        )
        let alpha = try makePendingSlot(
            rootEpoch: rootEpoch,
            fileID: uuid("00000000-0000-0000-0000-000000000020"),
            path: "Sources/Alpha.swift",
            pipeline: pipeline
        )
        let coverage = try WorkspaceCodemapGraphCatalogCoverage.validated(
            rootEpoch: rootEpoch,
            catalogWatermark: makeCatalogToken(rootEpoch: rootEpoch),
            enumerationState: .partial,
            supportedCount: 2,
            classifiedCount: 0,
            pendingCount: 2,
            contributedCount: 0,
            emptyCount: 0,
            terminalArtifactCount: 0,
            terminalExcludedCount: 0
        ).get()
        let checkpoint = try WorkspaceCodemapGraphCheckpoint.validated(
            rootEpoch: rootEpoch,
            repositoryAuthority: makeRepositoryAuthority(),
            generation: .init(rawValue: 11),
            schemaVersion: CodeMapSelectionGraphContribution.currentSchemaVersion,
            policyVersion: CodeMapSelectionGraphContribution.currentPolicyVersion,
            slots: [zeta, alpha],
            coverage: coverage
        ).get()
        XCTAssertEqual(checkpoint.slots.map(\.standardizedRelativePath), [
            "Sources/Alpha.swift",
            "Sources/Zeta.swift"
        ])

        XCTAssertEqual(
            try WorkspaceCodemapGraphCheckpoint.validated(
                rootEpoch: rootEpoch,
                repositoryAuthority: makeRepositoryAuthority(),
                generation: .init(rawValue: 11),
                schemaVersion: CodeMapSelectionGraphContribution.currentSchemaVersion,
                policyVersion: CodeMapSelectionGraphContribution.currentPolicyVersion,
                slots: [alpha],
                coverage: coverage
            ),
            .failure(.coverageCountMismatch)
        )
    }

    func testRemovalFenceAndPullContractsKeepDestructiveChangesExplicit() throws {
        let rootEpoch = makeRootEpoch(seed: 7)
        let fileID = uuid("00000000-0000-0000-0000-000000000030")
        let replaced = try XCTUnwrap(WorkspaceCodemapGraphRemoval(
            rootEpoch: rootEpoch,
            fileID: fileID,
            standardizedRelativePath: "Sources/Value.swift",
            reason: .replaced
        ))
        let deleted = try XCTUnwrap(WorkspaceCodemapGraphRemoval(
            rootEpoch: rootEpoch,
            fileID: fileID,
            standardizedRelativePath: "Sources/Value.swift",
            reason: .deleted
        ))
        XCTAssertFalse(replaced.reason.requiresSafetyFence)
        XCTAssertTrue(deleted.reason.requiresSafetyFence)
        XCTAssertNil(WorkspaceCodemapGraphRemoval(
            rootEpoch: rootEpoch,
            fileID: fileID,
            standardizedRelativePath: "Sources/../Value.swift",
            reason: .renamed
        ))

        let generation = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 12)
        XCTAssertEqual(
            WorkspaceCodemapGraphChangesDisposition.unchanged(generation: generation),
            .unchanged(generation: generation)
        )
        XCTAssertEqual(
            WorkspaceCodemapGraphFenceDisposition.fenced(safetyCounter: 4),
            .fenced(safetyCounter: 4)
        )
        XCTAssertEqual(
            WorkspaceCodemapGraphReceiptDisposition.invalid(.fencedFileOverlap),
            .invalid(.fencedFileOverlap)
        )
    }

    func testSnapshotReceiptRejectsCrossRootWatermarkAndKeepsFreshnessInternal() throws {
        let rootEpoch = makeRootEpoch(seed: 8)
        let receipt = try XCTUnwrap(try WorkspaceCodemapGraphSnapshotReceipt(
            snapshotID: uuid("00000000-0000-0000-0000-000000000040"),
            graphRevision: 3,
            rootEpoch: rootEpoch,
            repositoryAuthority: makeRepositoryAuthority(),
            catalogWatermark: makeCatalogToken(rootEpoch: rootEpoch),
            appliedGeneration: .init(rawValue: 5),
            safetyCounter: 2,
            schemaVersion: 1,
            policyVersion: 1
        ))
        XCTAssertEqual(receipt.rootEpoch, rootEpoch)
        XCTAssertEqual(
            WorkspaceCodemapGraphSnapshotFreshness.updatesPending(observedGeneration: .init(rawValue: 6)),
            .updatesPending(observedGeneration: .init(rawValue: 6))
        )
        XCTAssertNil(try WorkspaceCodemapGraphSnapshotReceipt(
            snapshotID: UUID(),
            graphRevision: 3,
            rootEpoch: rootEpoch,
            repositoryAuthority: makeRepositoryAuthority(),
            catalogWatermark: makeCatalogToken(rootEpoch: makeRootEpoch(seed: 9)),
            appliedGeneration: .init(rawValue: 5),
            safetyCounter: 2,
            schemaVersion: 1,
            policyVersion: 1
        ))
        XCTAssertEqual(
            Set([WorkspaceCodemapGraphUnresolvedReason.notIndexedYet, .missing, .tooCommon]).count,
            3
        )
    }

    func testSinglePolicyEnforcesChangedSetCoalesceInvariantAndDerivesBudgets() {
        let policy = WorkspaceCodemapGraphPolicy.initial
        XCTAssertLessThanOrEqual(
            policy.maximumChangedSetFileIDCount,
            policy.maximumCoalescedFileIDCount
        )
        XCTAssertEqual(policy.candidateOverflowThreshold, policy.graphSizePolicy.maxDefinitionCandidates)
        XCTAssertNil(WorkspaceCodemapGraphPolicy(
            maximumChangedSetFileIDCount: 2,
            maximumCoalescedFileIDCount: 1
        ))

        let clampedLow = policy.queryBudget(maximumTokenCount: 1, includesSignatures: true)
        XCTAssertEqual(clampedLow.maximumTokenCount, 1000)
        XCTAssertEqual(clampedLow.graphEvidenceTokenCount, 250)
        XCTAssertEqual(clampedLow.renderTokenCount, 750)

        let graphOnly = policy.queryBudget(maximumTokenCount: Int.max, includesSignatures: false)
        XCTAssertEqual(graphOnly.maximumTokenCount, 25000)
        XCTAssertEqual(graphOnly.maximumNodeCount, 200)
        XCTAssertEqual(graphOnly.maximumEdgeCount, 10000)
        XCTAssertEqual(graphOnly.graphEvidenceTokenCount, 25000)
        XCTAssertEqual(graphOnly.renderTokenCount, 0)
    }

    private func makeRootEpoch(seed: UInt8) -> WorkspaceCodemapRootEpoch {
        WorkspaceCodemapRootEpoch(
            rootID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            rootLifetimeID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        )
    }

    private func makeCatalogToken(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapGraphIndexCatalogToken {
        WorkspaceCodemapGraphIndexCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 2,
            catalogGeneration: 3,
            ingressGeneration: 4,
            graphIndexInvalidationGeneration: 5
        )
    }

    private func makeCatalogCandidate(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        path: String
    ) throws -> WorkspaceCodemapGraphIndexCatalogCandidate {
        try WorkspaceCodemapGraphIndexCatalogCandidate(
            identity: makeIdentity(rootEpoch: rootEpoch, fileID: fileID, path: path),
            language: .swift,
            requestGeneration: 1,
            pathGeneration: 1
        )
    }

    private func makePendingSlot(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        path: String,
        pipeline: CodeMapPipelineIdentity
    ) throws -> WorkspaceCodemapGraphSlot {
        try WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: makeIdentity(rootEpoch: rootEpoch, fileID: fileID, path: path),
            requestGeneration: 1,
            pathGeneration: 1,
            pipelineIdentity: pipeline,
            state: .pending
        ).get()
    }

    private func makeIdentity(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        path: String
    ) throws -> WorkspaceCodemapArtifactBindingIdentity {
        try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: "/workspace",
            standardizedRelativePath: path,
            standardizedFullPath: "/workspace/\(path)"
        ))
    }

    private func makePipeline() throws -> CodeMapPipelineIdentity {
        try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
    }

    private func makeArtifactKey(
        pipeline: CodeMapPipelineIdentity,
        seed: UInt8
    ) -> CodeMapArtifactKey {
        CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: seed, count: 32)),
            rawByteCount: UInt64(seed),
            pipelineIdentity: pipeline
        )
    }

    private func makeRepositoryAuthority() throws -> WorkspaceCodemapRepositoryAuthorityToken {
        try WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: 1,
            repositoryNamespace: GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32)),
            objectFormat: .sha1,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            attributeGeneration: "attributes",
            sparseGeneration: "sparse",
            metadataGeneration: "metadata"
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
