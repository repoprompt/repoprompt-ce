import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapPresentationTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testProjectionCatalogPagesAndCallbacksRequireExactCurrentShard() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Zeta.swift": SwiftFixtureSource.emptyStruct("Zeta"),
            "Sources/Alpha.swift": SwiftFixtureSource.emptyStruct("Alpha"),
            "Sources/Unsupported.txt": "unsupported\n",
            "Sources/Beta.py": "class Beta:\n    pass\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let catalog = fixture.registry.makeBindingCatalogClient()
        let alphaPathByteCount = UInt64("Sources/Alpha.swift".utf8.count)
        let firstPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 2,
                maximumPathByteCount: alphaPathByteCount
            )
        ))
        XCTAssertEqual(firstPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Alpha.swift"])
        XCTAssertEqual(firstPage.pathByteCount, alphaPathByteCount)
        XCTAssertEqual(firstPage.supportedCandidateCountThroughPage, 1)
        XCTAssertFalse(firstPage.isEnd)
        XCTAssertEqual(firstPage.entries.first?.identity.rootID, loaded.id)
        XCTAssertEqual(firstPage.entries.first?.identity.rootLifetimeID, ticket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(firstPage.entries.first?.identity.standardizedRootPath, loaded.standardizedFullPath)

        let secondPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: XCTUnwrap(firstPage.nextCursor),
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertEqual(secondPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Beta.py"])
        XCTAssertEqual(secondPage.supportedCandidateCountThroughPage, 2)
        XCTAssertFalse(secondPage.isEnd)

        let thirdPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: XCTUnwrap(secondPage.nextCursor),
                maximumEntryCount: 8,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertEqual(thirdPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Zeta.swift"])
        XCTAssertEqual(thirdPage.supportedCandidateCountThroughPage, 3)
        XCTAssertTrue(thirdPage.isEnd)
        XCTAssertNil(thirdPage.nextCursor)

        let currentToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            firstPage.token
        )
        XCTAssertEqual(currentToken, .current)
        let invalidCursorPage = await catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: "Sources/Alpha.swift",
                    fileID: UUID()
                ),
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        )
        XCTAssertEqual(invalidCursorPage, .stale)

        let namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32))
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: firstPage.token,
            repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken(
                authorityGeneration: 1,
                repositoryNamespace: namespace,
                objectFormat: .sha1,
                repositoryBindingEpoch: "repository",
                worktreeBindingEpoch: "worktree",
                layoutGeneration: "layout",
                indexGeneration: "index",
                checkoutConfigurationGeneration: "checkout",
                attributeGeneration: "attributes",
                sparseGeneration: "sparse",
                metadataGeneration: "metadata"
            ),
            contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        )
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: firstPage.entries[0].language,
            decoderPolicy: .workspaceAutomaticV1
        )
        let projectionEntry = WorkspaceCodemapProjectionEntry(
            identity: firstPage.entries[0].identity,
            requestGeneration: firstPage.entries[0].requestGeneration,
            pathGeneration: firstPage.entries[0].pathGeneration,
            pipelineIdentity: pipeline,
            outcome: .terminalExcluded(.securityExcluded)
        )
        let segmentByteCount: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: [projectionEntry]
        ) {
        case let .success(value):
            segmentByteCount = value
        case let .failure(error):
            return XCTFail("Unexpected segment byte accounting failure: \(error)")
        }
        let segmentProgress = WorkspaceCodemapProjectionProgress(
            phase: .publishingProjectionSegment,
            counts: WorkspaceCodemapProjectionCounts(
                supportedCandidateCount: 3,
                processedCandidateCount: 1,
                contributedCount: 0,
                emptyCount: 0,
                terminalArtifactCount: 0,
                terminalExcludedCount: 1,
                transientCount: 0
            ),
            catalogPageCount: 3,
            catalogPathByteCount: 0,
            publishedSegmentCount: 1,
            publishedSegmentByteCount: segmentByteCount,
            catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion(
                token: firstPage.token,
                finalCursor: WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: "Sources/Zeta.swift",
                    fileID: thirdPage.entries[0].identity.fileID
                ),
                supportedCandidateCount: 3
            )
        )
        let segment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 0,
            entries: [projectionEntry],
            progress: segmentProgress,
            byteCount: segmentByteCount
        ) {
        case let .success(value):
            segment = value
        case let .failure(error):
            return XCTFail("Unexpected segment validation failure: \(error)")
        }
        let accepted = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(accepted, .accepted(segmentProgress))

        let wrongPipeline = try SyntaxManager().pipelineIdentity(
            for: .python,
            decoderPolicy: .workspaceAutomaticV1
        )
        let wrongPipelineSegment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 1,
            entries: [WorkspaceCodemapProjectionEntry(
                identity: firstPage.entries[0].identity,
                requestGeneration: firstPage.entries[0].requestGeneration,
                pathGeneration: firstPage.entries[0].pathGeneration,
                pipelineIdentity: wrongPipeline,
                outcome: .terminalExcluded(.securityExcluded)
            )],
            progress: .notStarted,
            byteCount: 1
        ) {
        case let .success(value):
            wrongPipelineSegment = value
        case let .failure(error):
            return XCTFail("Unexpected wrong-pipeline segment validation failure: \(error)")
        }
        let wrongPipelineDisposition = await catalog.publishProjection(.segment(wrongPipelineSegment))
        XCTAssertEqual(wrongPipelineDisposition, .stale)

        await gate.release()
        try await assertNonGitTerminal(settledResult(store: store, ticket: ticket))
        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: alpha.standardizedRelativePath,
            newContent: SwiftFixtureSource.emptyStruct("AlphaChanged")
        )

        let staleToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            firstPage.token
        )
        XCTAssertEqual(staleToken, .stale)
        let staleProjection = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(staleProjection, .stale)
        let refreshedPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertNotEqual(refreshedPage.token, firstPage.token)
        XCTAssertEqual(refreshedPage.entries.first?.pathGeneration, ticket.pathGeneration + 1)

        await store.unloadRoot(id: loaded.id)
        let supersededProjection = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(supersededProjection, .superseded)
        let unloadedToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            refreshedPage.token
        )
        XCTAssertEqual(unloadedToken, .unavailable(.rootNotCurrent))
    }

    func testFrozenPresentationBundleRetainsReadyHandleLeaseAcrossAwaitAndRendersLogicalPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Alpha.swift": """
                protocol AlphaProtocol {
                    func alpha() -> String
                }

                struct Alpha: AlphaProtocol {
                    func alpha() -> String { "alpha" }
                }
                """,
                "Sources/Zeta.swift": """
                protocol ZetaProtocol {
                    func zeta() -> String
                }

                struct Zeta: ZetaProtocol {
                    func zeta() -> String { "zeta" }
                }
                """
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let suspensionGate = CodemapSuspensionGate()
        addTeardownBlock {
            await suspensionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let zeta = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Zeta.swift"
        })
        let alphaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let alphaArtifactKey: CodeMapArtifactKey
        do {
            let alphaReady = try await readyResult(
                settledResult(store: store, ticket: alphaTicket)
            )
            alphaArtifactKey = alphaReady.snapshot.artifactKey
        }
        let zetaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: zeta.id)
        )
        let zetaArtifactKey: CodeMapArtifactKey
        do {
            let zetaReady = try await readyResult(
                settledResult(store: store, ticket: zetaTicket)
            )
            zetaArtifactKey = zetaReady.snapshot.artifactKey
        }
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: root.path,
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedFullPath
        ))
        let alphaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        let zetaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: zeta.standardizedRelativePath
        ))
        let engine = try fixture.runtime().bindingEngine()
        let accountingBeforeFreeze = await engine.accounting()

        var callerBundle: WorkspaceCodemapFrozenPresentationBundle? = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: zetaTicket, logicalPath: zetaPath),
                WorkspaceCodemapPresentationRequest(ticket: alphaTicket, logicalPath: alphaPath)
            ])
        )
        do {
            let bundle = try XCTUnwrap(callerBundle)
            XCTAssertEqual(bundle.rootEpoch, alphaTicket.rootEpoch)
            XCTAssertEqual(
                bundle.entries.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey),
                [alphaArtifactKey, zetaArtifactKey]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey.pipelineIdentity),
                [
                    alphaArtifactKey.pipelineIdentity,
                    zetaArtifactKey.pipelineIdentity
                ]
            )

            let rendered = try await renderedPresentationEntries(
                store.renderCodemapPresentation(bundle)
            )
            XCTAssertEqual(
                rendered.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertTrue(rendered[0].text.contains("File: Logical Workspace/Sources/Alpha.swift"))
            XCTAssertTrue(rendered[1].text.contains("File: Logical Workspace/Sources/Zeta.swift"))
            XCTAssertFalse(rendered.contains { $0.text.contains(root.path) })
            XCTAssertTrue(rendered.allSatisfy { $0.tokenCount > 0 })

            let accountingAfterRender = await engine.accounting()
            XCTAssertEqual(
                accountingAfterRender.counters.validatedWorktreeReads,
                accountingBeforeFreeze.counters.validatedWorktreeReads
            )
            XCTAssertEqual(accountingAfterRender.counters.builds, accountingBeforeFreeze.counters.builds)
            XCTAssertEqual(
                accountingAfterRender.counters.manifestLoads,
                accountingBeforeFreeze.counters.manifestLoads
            )
            XCTAssertEqual(fixture.buildCount.value, 2)
        }
        var suspendedRenderTask: Task<WorkspaceCodemapPresentationRenderDisposition, Never>?
        if let bundle = callerBundle {
            suspendedRenderTask = Task { [bundle] in
                await suspensionGate.enterAndWait()
                return await store.renderCodemapPresentation(bundle)
            }
        }
        let suspensionEntered = await suspensionGate.waitUntilEntered()
        XCTAssertTrue(suspensionEntered)
        if let bundle = callerBundle {
            let bundleReleased = await store.releaseCodemapPresentation(bundle)
            XCTAssertTrue(bundleReleased)
        } else {
            XCTFail("The caller bundle must remain alive until its gated owner captures it.")
        }
        callerBundle = nil
        let didCancelAlphaDemand = await store.cancelCodemapArtifactDemand(alphaTicket)
        let didCancelZetaDemand = await store.cancelCodemapArtifactDemand(zetaTicket)
        XCTAssertTrue(didCancelAlphaDemand)
        XCTAssertTrue(didCancelZetaDemand)

        await store.unloadRoot(id: loaded.id)
        let runtime = try fixture.runtime()
        let leaseClock = ContinuousClock()
        let callerRetainedAccounting = await runtime.artifactStore.accounting()
        XCTAssertGreaterThanOrEqual(callerRetainedAccounting.activeLeaseCount, 2)
        XCTAssertGreaterThan(callerRetainedAccounting.activeLeaseBytes, 0)
        let expectedRemainingLeaseCount = callerRetainedAccounting.activeLeaseCount - 2

        await suspensionGate.release()
        let suspendedRender = await suspendedRenderTask?.value
        if let suspendedRender {
            assertPresentationRenderUnavailable(suspendedRender, equals: .bundleNotRetained)
        } else {
            XCTFail("The suspended caller render task must exist.")
        }
        suspendedRenderTask = nil

        let fullyReleasedDeadline = leaseClock.now.advanced(by: .seconds(2))
        var fullyReleasedAccounting = await runtime.artifactStore.accounting()
        while fullyReleasedAccounting.activeLeaseCount != expectedRemainingLeaseCount,
              leaseClock.now < fullyReleasedDeadline
        {
            try await Task.sleep(for: .milliseconds(25))
            fullyReleasedAccounting = await runtime.artifactStore.accounting()
        }
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseCount, expectedRemainingLeaseCount)
        XCTAssertLessThan(fullyReleasedAccounting.activeLeaseBytes, callerRetainedAccounting.activeLeaseBytes)
    }

    func testOperationPresentationCoordinatesMultiRootLogicalOutputAndReleasesAllRetains() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "physical-first-secret",
            files: ["Sources/First.swift": "protocol FirstProtocol { func first() -> String }\nstruct First: FirstProtocol { func first() -> String { \"first\" } }\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "physical-second-secret",
            files: ["Sources/Second.swift": "protocol SecondProtocol { func second() -> String }\nstruct Second: SecondProtocol { func second() -> String { \"second\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let secondFile = try XCTUnwrap(secondFiles.first)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [secondFile.id, firstFile.id], completeRootSet: false),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [
                    firstLoaded.id: "LogicalFirst",
                    secondLoaded.id: "LogicalSecond"
                ]
            )

        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.orderedEntries.count, 2)
        XCTAssertEqual(Set(presentation.orderedEntries.map(\.rootEpoch)).count, 2)
        XCTAssertEqual(
            presentation.orderedEntries.map(\.logicalPath.displayPath),
            ["LogicalFirst/Sources/First.swift", "LogicalSecond/Sources/Second.swift"]
        )
        XCTAssertTrue(presentation.orderedEntries.allSatisfy { $0.tokenCount == TokenCalculationService.estimateTokens(for: $0.text) })
        XCTAssertFalse(presentation.orderedEntries.contains { $0.text.contains(firstRoot.path) || $0.text.contains(secondRoot.path) })
        let receipt = try XCTUnwrap(presentation.publicationReceipt)
        for ticket in receipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in receipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationMixedReadyAndPendingPublishesReadyReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { func value() -> Int { 1 } }\n",
                "Sources/Pending.swift": "struct Pending { func value() -> Int { 2 } }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let pendingFileID = CodemapLockedValues<UUID>()
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            if pendingFileID.values.contains(ticket.fileID) {
                return .busy(retryAfterMilliseconds: 1000)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let ready = try XCTUnwrap(files.first { $0.name == "Ready.swift" })
        let pending = try XCTUnwrap(files.first { $0.name == "Pending.swift" })
        pendingFileID.append(pending.id)
        let warmResult = await store.requestCodemapArtifact(forFileID: ready.id)
        let warmReady: WorkspaceCodemapArtifactDemandReady
        switch warmResult {
        case let .ready(value):
            warmReady = value
        case let .pending(ticket):
            warmReady = try await readyResult(
                settledResult(store: store, ticket: ticket)
            )
        case let .unavailable(reason):
            XCTFail("Expected ready warm demand, got \(reason)")
            throw CodemapStoreTestError.timedOut
        }
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            ),
            beforePublicationRevalidation: { receipts.append($0) }
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [pending.id, ready.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case .partial = presentation.coverage else {
            return XCTFail("A ready sibling must remain publishable while another demand is pending")
        }
        XCTAssertEqual(presentation.orderedEntries.map(\.fileID), [ready.id])
        let receipt = try XCTUnwrap(receipts.values.first)
        XCTAssertEqual(receipt.candidates.map(\.fileID), [ready.id])
        XCTAssertEqual(receipt.demandTickets.map(\.fileID), [ready.id])
        XCTAssertTrue(receipt.bundles.allSatisfy { bundle in
            bundle.entries.allSatisfy { $0.ticket.fileID == ready.id }
        })
        _ = await store.cancelCodemapArtifactDemand(warmReady.ticket)
    }

    func testStaleEngineCompletionMapsToStaleCurrentness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Stale.swift": SwiftFixtureSource.emptyStruct("Stale")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let demandResults = CodemapLockedCounter()
        let store = fixture.makeStore(demandResultHook: { _, result in
            demandResults.increment()
            if demandResults.value == 1 {
                return .rejected(.staleCompletion)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)

        let initial = await store.requestCodemapArtifact(forFileID: file.id)
        let result: WorkspaceCodemapArtifactDemandResult = switch initial {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        case .ready, .unavailable:
            initial
        }

        assertStale(result)

        let retryInitial = await store.requestCodemapArtifact(forFileID: file.id)
        let retryResult: WorkspaceCodemapArtifactDemandResult = switch retryInitial {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        case .ready, .unavailable:
            retryInitial
        }
        let ready = try readyResult(retryResult)
        XCTAssertEqual(demandResults.value, 2)
        _ = await store.cancelCodemapArtifactDemand(ready.ticket)
    }

    func testStructureSeedDemandLimitRejectsBeforeRuntimeOrBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": SwiftFixtureSource.emptyStruct("One"),
                "Sources/Two.swift": SwiftFixtureSource.emptyStruct("Two")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        XCTAssertEqual(files.count, 2)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumCandidateDemandCount: 1
            )
        )
        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: files.map(\.id),
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(presentation.outcome, .budget)
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(presentation.resolvedSeedCount, 0)
        XCTAssertTrue(presentation.issues.contains {
            if case .seedDemandLimit(attempted: 2, limit: 1) = $0 { return true }
            return false
        })
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            operationsAfter.structureSeedAdmissionRequests - operationsBefore.structureSeedAdmissionRequests,
            1
        )
        XCTAssertEqual(
            operationsAfter.selectedMetadataResolutionRequests - operationsBefore.selectedMetadataResolutionRequests,
            0
        )
        XCTAssertEqual(
            operationsAfter.presentationCandidateRequests - operationsBefore.presentationCandidateRequests,
            0
        )
        XCTAssertEqual(operationsAfter.artifactDemandRequests - operationsBefore.artifactDemandRequests, 0)
        XCTAssertEqual(operationsAfter.presentationFreezeRequests - operationsBefore.presentationFreezeRequests, 0)
        XCTAssertEqual(operationsAfter.setupTasksCreated - operationsBefore.setupTasksCreated, 0)
        XCTAssertEqual(operationsAfter.demandTasksCreated - operationsBefore.demandTasksCreated, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testStructureSeedAdmissionIgnoresStaleAndOutOfScopeSeedsWithoutLosingIssues() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let allowedRootURL = try repositoryFixture.makeRepository(
            named: "allowed",
            files: ["Sources/Allowed.swift": SwiftFixtureSource.emptyStruct("Allowed")]
        )
        let outsideRootURL = try repositoryFixture.makeRepository(
            named: "outside",
            files: ["Sources/Outside.swift": SwiftFixtureSource.emptyStruct("Outside")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let allowedRoot = try await store.loadRoot(path: allowedRootURL.path)
        let outsideRoot = try await store.loadRoot(path: outsideRootURL.path)
        let allowedFiles = await store.files(inRoot: allowedRoot.id)
        let outsideFiles = await store.files(inRoot: outsideRoot.id)
        let allowedFile = try XCTUnwrap(allowedFiles.first)
        let outsideFile = try XCTUnwrap(outsideFiles.first)
        let staleFileID = UUID()
        let allowedRootRef = WorkspaceRootRef(
            id: allowedRoot.id,
            name: allowedRoot.name,
            fullPath: allowedRoot.standardizedFullPath
        )
        let rootScope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(
            canonicalRoots: [allowedRootRef],
            physicalRoots: []
        )
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumCandidateDemandCount: 1
            )
        )
        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [staleFileID, outsideFile.id, allowedFile.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 1,
                maximumEdgeCount: 1,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 1, maximumCodemapTokenCount: 0),
            rootScope: rootScope
        )

        XCTAssertFalse(presentation.issues.contains {
            if case .seedDemandLimit = $0 { return true }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case let .candidate(.fileNotCataloged(fileID)) = $0 {
                return fileID == staleFileID
            }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case let .candidate(.fileOutsideRootScope(fileID)) = $0 {
                return fileID == outsideFile.id
            }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case .tokenLimit = $0 { return true }
            return false
        })
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            operationsAfter.structureSeedAdmissionRequests - operationsBefore.structureSeedAdmissionRequests,
            1
        )
        XCTAssertEqual(
            operationsAfter.presentationCandidateRequests - operationsBefore.presentationCandidateRequests,
            1
        )
        XCTAssertEqual(operationsAfter.artifactDemandRequests - operationsBefore.artifactDemandRequests, 0)
        XCTAssertEqual(operationsAfter.presentationFreezeRequests - operationsBefore.presentationFreezeRequests, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testStructurePresentationSeedUsesPairedCodemapRenderAndReleasesReceiptResources() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let releasedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            releasedTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let phases = CodemapLockedValues<WorkspaceCodemapStructureExecutionPhase>()

        let presentation = try await WorkspaceCodemapPresentationCoordinator(
            store: store,
            structurePhaseDidChange: { phases.append($0) }
        )
        .structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(
                maximumFileCount: 10,
                maximumCodemapTokenCount: 6000
            ),
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )

        XCTAssertEqual(presentation.outcome, .ready)
        XCTAssertEqual(
            phases.values,
            [.seedDemand, .freeze, .render, .assembly, .publicationRevalidation]
        )
        let rendered = try XCTUnwrap(presentation.entries.first)
        XCTAssertTrue(rendered.isSeed)
        XCTAssertEqual(rendered.depth, 0)
        XCTAssertEqual(rendered.entry.logicalPath.displayPath, "Logical/Sources/Feature.swift")
        XCTAssertEqual(rendered.entry.tokenCount, TokenCalculationService.estimateTokens(for: rendered.entry.text))
        XCTAssertFalse(rendered.entry.text.contains(root.path))
        let ticket = try XCTUnwrap(releasedTickets.values.last)
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testStructureWarmPublishedArtifactBypassesDemandFreezeGraphAndGitIdentity() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(store: store)
        let traversalLimits = WorkspaceCodemapStructureTraversalLimits(
            maximumDepth: 0,
            maximumNodeCount: 10,
            maximumEdgeCount: 10,
            maximumByteCount: 4096
        )
        let outputLimits = WorkspaceCodemapStructureOutputLimits(
            maximumFileCount: 10,
            maximumCodemapTokenCount: 6000
        )

        let published = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        XCTAssertEqual(published.outcome, .ready)

        let rendered = try XCTUnwrap(published.entries.first)
        let markerCleared = await store.clearCodemapMarkerReadinessForTesting(
            rootEpoch: rendered.entry.rootEpoch,
            fileID: file.id
        )
        XCTAssertTrue(markerCleared)
        let clearedMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let clearedMarkerSnapshot = try XCTUnwrap(clearedMarkerSnapshotValue)
        XCTAssertTrue(clearedMarkerSnapshot.changes.isEmpty)

        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()
        let engine = try fixture.runtime().bindingEngine()
        let engineBefore = await engine.accounting()
        let buildCountBefore = fixture.buildCount.value
        let firstWarm = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        let firstMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let firstMarkerSnapshot = try XCTUnwrap(firstMarkerSnapshotValue)
        let secondWarm = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        let secondMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let secondMarkerSnapshot = try XCTUnwrap(secondMarkerSnapshotValue)
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        let engineAfter = await engine.accounting()

        for warm in [firstWarm, secondWarm] {
            XCTAssertEqual(warm.outcome, .ready)
            XCTAssertEqual(warm.entries.map(\.entry.logicalPath.displayPath), ["Logical/Sources/Feature.swift"])
            XCTAssertEqual(warm.entries.map(\.entry.text), published.entries.map(\.entry.text))
        }
        XCTAssertEqual(firstMarkerSnapshot.revision, clearedMarkerSnapshot.revision + 1)
        XCTAssertEqual(firstMarkerSnapshot.changes.map(\.fileID), [file.id])
        XCTAssertEqual(firstMarkerSnapshot.changes.first?.state, .ready)
        XCTAssertEqual(secondMarkerSnapshot.revision, firstMarkerSnapshot.revision)
        XCTAssertEqual(secondMarkerSnapshot.changes, firstMarkerSnapshot.changes)
        XCTAssertEqual(operationsAfter, operationsBefore)
        XCTAssertEqual(fixture.buildCount.value, buildCountBefore)
        XCTAssertEqual(engineAfter.counters.capabilityResolutions, engineBefore.counters.capabilityResolutions)
        XCTAssertEqual(engineAfter.counters.classifications, engineBefore.counters.classifications)
        XCTAssertEqual(engineAfter.counters.manifestLoads, engineBefore.counters.manifestLoads)
        XCTAssertEqual(engineAfter.counters.manifestWrites, engineBefore.counters.manifestWrites)
        XCTAssertEqual(engineAfter.counters.builds, engineBefore.counters.builds)
        XCTAssertEqual(engineAfter.counters.materializations, engineBefore.counters.materializations)
        XCTAssertEqual(engineAfter.counters.validatedWorktreeReads, engineBefore.counters.validatedWorktreeReads)
        XCTAssertEqual(engineAfter.counters.projectionPreloadsStarted, engineBefore.counters.projectionPreloadsStarted)
        XCTAssertEqual(engineAfter.counters.projectionCatalogPages, engineBefore.counters.projectionCatalogPages)
        XCTAssertEqual(engineAfter.counters.projectionSegmentsPublished, engineBefore.counters.projectionSegmentsPublished)
        XCTAssertEqual(engineAfter.counters.projectionBuildsStarted, engineBefore.counters.projectionBuildsStarted)
        XCTAssertEqual(engineAfter.activeRequestCount, engineBefore.activeRequestCount)
        XCTAssertEqual(engineAfter.projectionJobCount, engineBefore.projectionJobCount)
        XCTAssertEqual(
            engineAfter.counters.publishedArtifactProjectionCASHits,
            engineBefore.counters.publishedArtifactProjectionCASHits + 2
        )
    }

    func testStructurePublicationRevocationRetriesThenReturnsTypedStale() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let publicationCount = CodemapLockedCounter()
        let structureAttempts = CodemapLockedValues<Int>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            ),
            beforePublicationRevalidation: { _ in
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            },
            structureAttemptDidBegin: { structureAttempts.append($0) }
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(
            presentation.outcome,
            .stale,
            "issues=\(presentation.issues), publications=\(publicationCount.value)"
        )
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(structureAttempts.values, [0, 1])
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertTrue(presentation.issues.contains {
            if case .publicationStale = $0 { return true }
            return false
        })
    }

    func testOperationPresentationRevocationBeforePublicationRetriesAndReturnsIncomplete() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "protocol FeatureProtocol { func feature() -> String }\nstruct Feature: FeatureProtocol { func feature() -> String { \"feature\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let publicationCount = CodemapLockedCounter()
        let operationCount = CodemapLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            beforePublicationRevalidation: { receipt in
                receipts.append(receipt)
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            }
        )

        let presentation = try await coordinator.withPresentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        ) { presentation in
            operationCount.increment()
            return presentation
        }

        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        guard case .unavailable = presentation.coverage else {
            return XCTFail("Revoked publication must return typed incomplete coverage")
        }
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertEqual(operationCount.value, 2)
        let firstReceipt = try XCTUnwrap(receipts.values.first)
        for ticket in firstReceipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in firstReceipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationCancellationDuringPendingWaitReleasesOwnedDemandOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let resolutionGate = CodemapResolutionGate()
        let waiterGate = CodemapSuspensionGate()
        let cleanupGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await cleanupGate.release()
            await waiterGate.release()
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
            await cleanupGate.enterAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            waiter: WorkspaceCodemapPresentationWaiter { _ in
                await waiterGate.enterAndWait()
                try Task.checkCancellation()
            }
        )
        let task = Task {
            try await coordinator.presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        }

        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let waiterEntered = await waiterGate.waitUntilEntered()
        XCTAssertTrue(waiterEntered)
        task.cancel()
        await waiterGate.release()
        await resolutionGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let cleanupEntered = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupEntered)
        let cancelledTicket = try XCTUnwrap(cancelledTickets.values.first)
        XCTAssertEqual(cancelledTickets.values.count, 1)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(cancelledTicket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: cancelledTicket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
        await cleanupGate.release()
    }

    func testScopedOperationCancellationAfterRenderReleasesDemandAndPresentationOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct ScopedCancellationFeature { func renderable() {} }\n"]
        )
        let operationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await operationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let operationReceiptTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(store: store)
        let task = Task {
            try await coordinator.withPresentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            ) { presentation in
                XCTAssertEqual(presentation.orderedEntries.count, 1)
                let receipt = try XCTUnwrap(presentation.publicationReceipt)
                XCTAssertEqual(receipt.demandTickets.count, 1)
                let receiptTicket = try XCTUnwrap(receipt.demandTickets.first)
                operationReceiptTickets.append(receiptTicket)
                await operationGate.enterAndWait()
                try Task.checkCancellation()
                return presentation
            }
        }

        let operationEntered = await operationGate.waitUntilEntered()
        XCTAssertTrue(operationEntered)
        task.cancel()
        await operationGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let receiptTicket = try XCTUnwrap(operationReceiptTickets.values.first)
        XCTAssertEqual(operationReceiptTickets.values.count, 1)
        let cleanupTickets = cancelledTickets.values
        XCTAssertLessThanOrEqual(cleanupTickets.count, 1)
        if let cleanupTicket = cleanupTickets.first {
            XCTAssertEqual(cleanupTicket, receiptTicket)
        }
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(receiptTicket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: receiptTicket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testOperationPresentationPendingIsTypedAndReleasedWithoutFallback() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            )
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case let .pending(issues) = presentation.coverage else {
            return XCTFail("Expected typed pending coverage")
        }
        let ticket = try XCTUnwrap(issues.compactMap { issue -> WorkspaceCodemapArtifactDemandTicket? in
            if case let .pending(_, ticket) = issue { return ticket }
            return nil
        }.first)
        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        XCTAssertNil(presentation.publicationReceipt)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
        await resolutionGate.release()
    }
}
