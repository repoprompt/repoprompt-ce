import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapGraphFreezeQueryTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testPresentationFreezeRejectsPendingForeignEpochDuplicateAndLogicalPathMismatch() async throws {
        let resolutionGate = CodemapResolutionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: firstFile.standardizedRelativePath
        ))
        let secondPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Second Logical Root",
            standardizedRelativePath: secondFile.standardizedRelativePath
        ))
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .pending(firstTicket)
        )

        await resolutionGate.release()
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: secondTicket, logicalPath: secondPath)
            ]),
            equals: .mixedRootEpoch
        )
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .duplicateFileID(firstFile.id)
        )

        let mismatchedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: "Sources/Elsewhere.swift"
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstTicket,
                    logicalPath: mismatchedPath
                )
            ]),
            equals: .logicalPathMismatch(firstFile.id)
        )

        let unretainedEntry = WorkspaceCodemapFrozenPresentationEntry(
            ticket: firstTicket,
            logicalPath: firstPath,
            artifactKey: firstReady.snapshot.artifactKey,
            outcome: firstReady.snapshot.outcome
        )
        let unretainedBundle = WorkspaceCodemapFrozenPresentationBundle(
            rootEpoch: firstTicket.rootEpoch,
            entries: [unretainedEntry],
            handles: [firstReady.handle]
        )
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unretainedBundle),
            equals: .bundleNotRetained
        )

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": "struct Plain {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: plainFile.id)
        )
        let plainSettled = try await settledResult(store: store, ticket: plainTicket)
        assertNonGitTerminal(plainSettled)
        let plainPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Plain Logical Root",
            standardizedRelativePath: plainFile.standardizedRelativePath
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: plainTicket, logicalPath: plainPath)
            ]),
            equals: .demandUnavailable(plainTicket, .gitTerminal(.nonGit))
        )

        let validBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ])
        )
        let validBundleReleased = await store.releaseCodemapPresentation(validBundle)
        XCTAssertTrue(validBundleReleased)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testPresentationRenderFailsClosedAfterDemandCancellationCatalogAdvanceAndUnload() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let cancellationRoot = try repositoryFixture.makeRepository(
            named: "cancellation",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let catalogRoot = try repositoryFixture.makeRepository(
            named: "catalog",
            files: ["Sources/Catalog.swift": "struct Catalog {}\n"]
        )
        let unloadRoot = try repositoryFixture.makeRepository(
            named: "unload",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let cancellationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await cancellationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(cancellationCleanupHook: { _ in
            await cancellationGate.enterAndWait()
        })

        let cancellationLoaded = try await store.loadRoot(path: cancellationRoot.path)
        let cancellationFiles = await store.files(inRoot: cancellationLoaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(cancellationFiles.count, 2)
        let firstCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[0].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: firstCancellationTicket)
        )
        let secondCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[1].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: secondCancellationTicket)
        )
        let cancellationBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[0].standardizedRelativePath
                    ))
                ),
                WorkspaceCodemapPresentationRequest(
                    ticket: secondCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[1].standardizedRelativePath
                    ))
                )
            ])
        )

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(firstCancellationTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(cancellationBundle),
            equals: .bundleNotRetained
        )
        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)

        let catalogLoaded = try await store.loadRoot(path: catalogRoot.path)
        let catalogFiles = await store.files(inRoot: catalogLoaded.id)
        let catalogFile = try XCTUnwrap(catalogFiles.first)
        let catalogTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: catalogFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: catalogTicket))
        let catalogPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Catalog Logical Root",
            standardizedRelativePath: catalogFile.standardizedRelativePath
        ))
        let releaseBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let catalogBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let firstRelease = await store.releaseCodemapPresentation(releaseBundle)
        let secondRelease = await store.releaseCodemapPresentation(releaseBundle)
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(secondRelease)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(releaseBundle),
            equals: .bundleNotRetained
        )

        try Self.write(
            "struct Added {}\n",
            to: catalogRoot.appendingPathComponent("Sources/Added.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            catalogRoot.appendingPathComponent("Sources/Added.swift").path
        ])
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(catalogBundle),
            equals: .bundleNotRetained
        )

        let unloadLoaded = try await store.loadRoot(path: unloadRoot.path)
        let unloadFiles = await store.files(inRoot: unloadLoaded.id)
        let unloadFile = try XCTUnwrap(unloadFiles.first)
        let unloadTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unloadFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: unloadTicket))
        let unloadBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: unloadTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Unload Logical Root",
                        standardizedRelativePath: unloadFile.standardizedRelativePath
                    ))
                )
            ])
        )
        await store.unloadRoot(id: unloadLoaded.id)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unloadBundle),
            equals: .bundleNotRetained
        )

        await store.unloadRoot(id: cancellationLoaded.id)
        await store.unloadRoot(id: catalogLoaded.id)
    }

    func testReadyPublicationsTargetFreezeIndividuallyAndCoalesceOneRootGraphFreeze() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let graphGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(files.count, 2)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: files[0].id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: files[1].id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        let blockedCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(blockedCounts.targetedReadyFreezes, 2)
        XCTAssertEqual(blockedCounts.graphBatchSignals, 2)
        XCTAssertEqual(blockedCounts.graphBatchFlushes, 0)
        XCTAssertEqual(blockedCounts.fullRootGraphFreezes, 0)
        XCTAssertEqual(blockedCounts.graphWorkerStarts, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await graphGate.release()
        let graphPublished = await graphProbe.waitUntilPublished(rootEpoch: firstTicket.rootEpoch)
        XCTAssertTrue(graphPublished)

        let publishedCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(publishedCounts.targetedReadyFreezes, 2)
        XCTAssertEqual(publishedCounts.graphBatchSignals, 2)
        XCTAssertEqual(publishedCounts.graphBatchFlushes, 1)
        XCTAssertEqual(publishedCounts.fullRootGraphFreezes, 1)
        XCTAssertEqual(publishedCounts.graphWorkerStarts, 1)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsBlockedGraphPublicationFlightWithoutLateWorker() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let graphGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        await store.unloadRoot(id: loaded.id)

        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.targetedReadyFreezes, 1)
        XCTAssertEqual(counts.fullRootGraphFreezes, 0)
        XCTAssertEqual(counts.graphWorkerStarts, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testReadyArtifactProducesFileTreeMarkerBeforeGraphPublication() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Target {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let graphGate = CodemapGraphPublicationGate()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        let markerBeforeTreeValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let markerBeforeTree = try XCTUnwrap(markerBeforeTreeValue)
        XCTAssertEqual(markerBeforeTree.changes.map(\.fileID), [file.id])
        let engineBeforeTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: loaded.id
        )
        let engineBeforeTree = try XCTUnwrap(engineBeforeTreeValue)
        let buildCountBeforeTree = fixture.buildCount.value
        let graphFactoryCountBeforeTree = graphProbe.factoryCount
        let countsBeforeTree = await store.codemapPresentationOperationCountsForTesting()

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(
                rootScope: .allLoaded,
                bindingProjection: nil
            )
        )

        XCTAssertTrue(tree.content.contains("Feature.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("(+ denotes code-map available)"), tree.content)
        XCTAssertEqual(fixture.buildCount.value, buildCountBeforeTree)
        let markerAfterTree = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(markerAfterTree?.revision, markerBeforeTree.revision)
        XCTAssertEqual(markerAfterTree?.changes, markerBeforeTree.changes)
        let engineAfterTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: loaded.id
        )
        let engineAfterTree = try XCTUnwrap(engineAfterTreeValue)
        XCTAssertEqual(engineAfterTree, engineBeforeTree)
        let countsAfterTree = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(countsAfterTree, countsBeforeTree)
        XCTAssertEqual(graphProbe.factoryCount, graphFactoryCountBeforeTree)

        await graphGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testGetFileTreeCurrentSnapshotDoesNotAwaitOrRetainBlockedCodemapDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            resolutionGate: resolutionGate,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let markerReady = expectation(description: "marker readiness published")
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let readinessObservation = Task {
            for await event in readinessStream
                where event.rootEpoch == ticket.rootEpoch && event.changes.contains(where: {
                    $0.fileID == file.id && $0.state == .ready
                })
            {
                markerReady.fulfill()
                return
            }
        }

        let countsBeforePendingTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountBeforePendingTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let request = WorkspaceFileTreePresentationRequest(
            mode: .full,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: false,
            showCodeMapMarkers: true,
            rootScope: .allLoaded
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: .allLoaded,
            bindingProjection: nil
        )

        let pendingTreeClock = ContinuousClock()
        let pendingTreeDeadline = pendingTreeClock.now.advanced(by: .seconds(1))
        let pendingTreeCompletion = CodemapBoundedCompletionState()
        let pendingTreeTask = Task {
            let tree = await store.makeCurrentSnapshotFileTreePresentation(
                selection: StoredSelection(),
                request: request,
                lookupContext: lookupContext,
                profile: .mcpRead
            )
            pendingTreeCompletion.recordCompletion(
                beforeDeadline: pendingTreeClock.now < pendingTreeDeadline
            )
            return tree
        }
        let pendingTreeCompleted = await waitForCompletionBeforeExternalDeadline(
            pendingTreeCompletion,
            clock: pendingTreeClock,
            deadline: pendingTreeDeadline
        )
        guard pendingTreeCompleted else {
            await resolutionGate.release()
            pendingTreeTask.cancel()
            let drained = await waitForBoundedCompletionDrain(pendingTreeCompletion)
            readinessObservation.cancel()
            await readinessObservation.value
            return XCTFail(
                "File-tree render awaited blocked codemap demand; bounded drain completed: \(drained)."
            )
        }
        let pendingTree = await pendingTreeTask.value

        XCTAssertTrue(pendingTree.content.contains("Feature.swift"), pendingTree.content)
        XCTAssertFalse(pendingTree.content.contains("Feature.swift +"), pendingTree.content)
        let countsAfterPendingTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountAfterPendingTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(countsAfterPendingTree, countsBeforePendingTree)
        XCTAssertEqual(retainCountAfterPendingTree, retainCountBeforePendingTree)

        await resolutionGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        await fulfillment(of: [markerReady], timeout: 1)
        readinessObservation.cancel()
        await readinessObservation.value
        let countsBeforeReadyTree = await store.codemapPresentationOperationCountsForTesting()
        let readyTree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: request,
            lookupContext: lookupContext,
            profile: .mcpRead
        )

        XCTAssertTrue(readyTree.content.contains("Feature.swift +"), readyTree.content)
        let countsAfterReadyTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountAfterReadyTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        // Ready demand publication owns graph publication asynchronously. While the passive
        // file-tree render awaits snapshot/logical-root work, already-scheduled graph
        // publication may advance. This path must still avoid demand, presentation, and
        // retain work.
        XCTAssertEqual(
            countsAfterReadyTree.structureSeedAdmissionRequests,
            countsBeforeReadyTree.structureSeedAdmissionRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.selectedMetadataResolutionRequests,
            countsBeforeReadyTree.selectedMetadataResolutionRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.presentationCandidateRequests,
            countsBeforeReadyTree.presentationCandidateRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.artifactDemandRequests,
            countsBeforeReadyTree.artifactDemandRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.presentationFreezeRequests,
            countsBeforeReadyTree.presentationFreezeRequests
        )
        XCTAssertEqual(countsAfterReadyTree.setupTasksCreated, countsBeforeReadyTree.setupTasksCreated)
        XCTAssertEqual(countsAfterReadyTree.demandTasksCreated, countsBeforeReadyTree.demandTasksCreated)
        XCTAssertEqual(
            countsAfterReadyTree.targetedReadyFreezes,
            countsBeforeReadyTree.targetedReadyFreezes
        )
        XCTAssertEqual(retainCountAfterReadyTree, retainCountBeforePendingTree)

        _ = await store.cancelCodemapArtifactDemand(ticket)
        await store.unloadRoot(id: loaded.id)
    }

    func testGetFileTreeCurrentSnapshotOmitsMarkerForReadyNoSymbols() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Empty.swift": "// no symbols\n"]
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
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        XCTAssertEqual(ready.snapshot.outcome, .readyNoSymbols)
        _ = await store.cancelCodemapArtifactDemand(ticket)
        let firstMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let firstMarkerSnapshot = try XCTUnwrap(firstMarkerSnapshotValue)

        let repeatedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let repeatedReady = try await readyResult(settledResult(store: store, ticket: repeatedTicket))
        XCTAssertEqual(repeatedReady.snapshot.outcome, .readyNoSymbols)
        _ = await store.cancelCodemapArtifactDemand(repeatedTicket)
        let repeatedMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let repeatedMarkerSnapshot = try XCTUnwrap(repeatedMarkerSnapshotValue)
        XCTAssertEqual(
            repeatedMarkerSnapshot.revision,
            firstMarkerSnapshot.revision,
            "Every marker event advances revision; repeated readyNoSymbols must emit neither."
        )
        XCTAssertEqual(repeatedMarkerSnapshot.changes, firstMarkerSnapshot.changes)
        let countsBeforeTree = await store.codemapPresentationOperationCountsForTesting()

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: true,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(
                rootScope: .allLoaded,
                bindingProjection: nil
            ),
            profile: .mcpRead
        )

        XCTAssertTrue(tree.content.contains("Empty.swift"), tree.content)
        XCTAssertFalse(tree.content.contains("Empty.swift +"), tree.content)
        let countsAfterTree = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(countsAfterTree, countsBeforeTree)

        await store.unloadRoot(id: loaded.id)
    }

    func testDurableProjectionPublishesMarkerReadinessAfterDemandRelease() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let readinessPublished = expectation(description: "durable marker readiness published")
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let readinessObservation = Task {
            for await event in readinessStream
                where event.rootEpoch.rootID == loaded.id && event.changes.contains(where: {
                    $0.fileID == file.id && $0.state == .ready
                })
            {
                readinessPublished.fulfill()
                return
            }
        }

        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        _ = await store.cancelCodemapArtifactDemand(ticket)
        await fulfillment(of: [readinessPublished], timeout: 1)
        readinessObservation.cancel()
        await readinessObservation.value

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("Feature.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionManifestFailureDoesNotPublishMarkerReadiness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let manifestFailureCount = CodemapLockedCounter()
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true,
            manifestStoreFaultAction: { point in
                guard point == .afterTemporaryWrite else { return .proceed }
                manifestFailureCount.increment()
                return .simulateProcessTermination
            }
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )

        let completeCoverage = await graphProbe.waitUntilCompleteCoverage(rootEpoch: rootEpoch)
        XCTAssertTrue(completeCoverage)
        XCTAssertGreaterThan(manifestFailureCount.value, 0)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("Feature.swift"), tree.content)
        XCTAssertFalse(tree.content.contains("Feature.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionManifestFailureRecoveredByLaterBatchPublishesAllMarkers() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let repositoryFiles = [
            "File000.swift": "struct Target000 {}\n",
            "File010.swift": "struct Target010 {}\n"
        ]
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let manifestWriteAttempts = CodemapManifestWriteAttemptLatch()
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true,
            bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy(
                maximumQueuedProjectionManifestMutationByteCountPerRoot: 8 * 1024,
                maximumQueuedProjectionManifestMutationByteCount: 64 * 1024
            ),
            manifestStoreFaultAction: { point in
                guard point == .afterTemporaryWrite else { return .proceed }
                return manifestWriteAttempts.recordAttempt() == 1
                    ? .simulateProcessTermination
                    : .proceed
            }
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "File000.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "File010.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let observedFirstWrite = await manifestWriteAttempts.waitForAttemptCount(1, timeout: .seconds(5))
        guard observedFirstWrite else {
            await store.unloadRoot(id: loaded.id)
            return XCTFail("Explicit engine admission produced zero manifest writes.")
        }

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let recoveredMarkers = expectation(description: "failed manifest batch recovered by later persistence")
        let readinessObservation = Task {
            var firstReady = false
            var secondReady = false
            for await event in readinessStream where event.rootEpoch == firstTicket.rootEpoch {
                for change in event.changes where change.state == .ready {
                    if change.fileID == firstTicket.fileID,
                       change.standardizedRelativePath == first.standardizedRelativePath,
                       change.requestGeneration == firstTicket.requestGeneration,
                       change.pathGeneration == firstTicket.pathGeneration
                    {
                        firstReady = true
                    }
                    if change.fileID == secondTicket.fileID,
                       change.standardizedRelativePath == second.standardizedRelativePath,
                       change.requestGeneration == secondTicket.requestGeneration,
                       change.pathGeneration == secondTicket.pathGeneration
                    {
                        secondReady = true
                    }
                }
                if firstReady, secondReady {
                    recoveredMarkers.fulfill()
                    return
                }
            }
        }
        let observedRecoveryWrite = await manifestWriteAttempts.waitForAttemptCount(2, timeout: .seconds(5))
        XCTAssertTrue(
            observedRecoveryWrite,
            "Recovery requires a later durable manifest write after the injected first failure."
        )
        await fulfillment(of: [recoveredMarkers], timeout: 5)
        readinessObservation.cancel()
        await readinessObservation.value

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("File000.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("File010.swift +"), tree.content)

        _ = await store.cancelCodemapArtifactDemand(firstTicket)
        _ = await store.cancelCodemapArtifactDemand(secondTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testTargetedInvalidationClearsOnlyAffectedMarkerReadiness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Changed.swift": "struct Changed {}\n",
                "Sources/Stable.swift": "struct Stable {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let changed = try XCTUnwrap(files.first { $0.name == "Changed.swift" })
        let stable = try XCTUnwrap(files.first { $0.name == "Stable.swift" })
        for file in [changed, stable] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }

        try Self.write(
            "struct Changed { let edited = true }\n",
            to: root.appendingPathComponent("Sources/Changed.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Changed.swift", nil)]
        )

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertFalse(tree.content.contains("Changed.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("Stable.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testMarkerReadinessIgnoresCrossRootAndStaleEpochUpdates() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRootURL = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRootURL = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let firstRoot = try await store.loadRoot(path: firstRootURL.path)
        let secondRoot = try await store.loadRoot(path: secondRootURL.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: firstFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        _ = await store.cancelCodemapArtifactDemand(ticket)

        let firstLifetimeID = try await store.rootLifetimeIDForTesting(rootID: firstRoot.id)
        let firstEpoch = WorkspaceCodemapRootEpoch(
            rootID: firstRoot.id,
            rootLifetimeID: firstLifetimeID
        )
        let crossRootAccepted = await store.acceptCodemapMarkerReadinessUpdateForTesting(
            WorkspaceCodemapMarkerReadinessUpdate(
                rootEpoch: firstEpoch,
                changes: [
                    WorkspaceCodemapMarkerReadinessChange(
                        fileID: secondFile.id,
                        standardizedRelativePath: secondFile.standardizedRelativePath,
                        requestGeneration: 0,
                        pathGeneration: 0,
                        state: .unavailable
                    )
                ]
            )
        )
        XCTAssertTrue(crossRootAccepted)

        let staleAccepted = await store.acceptCodemapMarkerReadinessUpdateForTesting(
            WorkspaceCodemapMarkerReadinessUpdate(
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: firstRoot.id,
                    rootLifetimeID: UUID()
                ),
                changes: [
                    WorkspaceCodemapMarkerReadinessChange(
                        fileID: firstFile.id,
                        standardizedRelativePath: firstFile.standardizedRelativePath,
                        requestGeneration: 0,
                        pathGeneration: 0,
                        state: .unavailable
                    )
                ]
            )
        )
        XCTAssertFalse(staleAccepted)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("First.swift +"), tree.content)
        XCTAssertFalse(tree.content.contains("Second.swift +"), tree.content)

        await store.unloadRoot(id: firstRoot.id)
        await store.unloadRoot(id: secondRoot.id)
    }

    func testAcceptedReadyOverlayLazilyBuildsOneExactEpochGraphButStrictQueryRemainsIncomplete() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let firstPublicationGate = CodemapArmableSuspensionGate()
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let initialGraphPolicy = WorkspaceCodemapSelectionGraphRuntimePolicy.initial
        let graphProbe = CodemapSelectionGraphProbe(runtimePolicy: .init(
            maximumActiveRebuildCount: initialGraphPolicy.maximumActiveRebuildCount,
            maximumReservedBindingCount: initialGraphPolicy.maximumReservedBindingCount,
            maximumInputBindingCount: initialGraphPolicy.maximumInputBindingCount,
            maximumSelectedSourceCountPerQuery: 1,
            maximumResolvedTargetCountPerQuery: initialGraphPolicy.maximumResolvedTargetCountPerQuery,
            maximumReferenceFailureCountPerQuery: initialGraphPolicy.maximumReferenceFailureCountPerQuery,
            graphSizePolicy: initialGraphPolicy.graphSizePolicy
        ))
        addTeardownBlock {
            await firstPublicationGate.release()
            await pendingPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await firstPublicationGate.enterIfArmedAndWait()
                await pendingPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let pending = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })

        await firstPublicationGate.arm()
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        let firstPublicationEntered = await firstPublicationGate.waitUntilEntered()
        XCTAssertTrue(firstPublicationEntered)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await firstPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let publicationDrainClock = ContinuousClock()
        let publicationDrained = await store.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: publicationDrainClock.now.advanced(by: .seconds(5))
        )
        XCTAssertTrue(publicationDrained)
        let sourceQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)
        ])
        let result = await store.queryCodemapSelectionGraph(sourceQuery)
        guard case let .incomplete(.definitionUniverse(rootEpoch, progress, remaining, retry)) = result
        else { return XCTFail("Live overlay must not materialize strict targets before a seal.") }
        XCTAssertEqual(rootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(progress, .notStarted)
        XCTAssertNil(remaining)
        XCTAssertNil(retry)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        let budgetedQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: targetTicket)
            ])
        )
        guard case let .incomplete(.definitionUniverse(
            budgetRootEpoch,
            budgetProgress,
            budgetRemaining,
            budgetRetry
        )) = budgetedQuery else {
            return XCTFail("Strict multi-source query must remain incomplete before a seal.")
        }
        XCTAssertEqual(budgetRootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(budgetProgress, .notStarted)
        XCTAssertNil(budgetRemaining)
        XCTAssertNil(budgetRetry)

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: pending.id)
        )
        let pendingPublicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(pendingPublicationEntered)
        let whilePending = await store.queryCodemapSelectionGraph(sourceQuery)
        guard case .incomplete = whilePending else {
            return XCTFail("Pending live work must leave strict graph queries incomplete.")
        }
        let pendingQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: pendingTicket)
            ])
        )
        XCTAssertEqual(pendingQuery, .unavailable(.sourceNotReady(pending.id)))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))

        try Self.write(
            "struct CatalogAdvance {}\n",
            to: root.appendingPathComponent("Sources/CatalogAdvance.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            root.appendingPathComponent("Sources/CatalogAdvance.swift").path
        ])
        let staleAfterCatalogAdvance = await store.queryCodemapSelectionGraph(sourceQuery)
        XCTAssertEqual(
            staleAfterCatalogAdvance,
            .stale(.currentness(sourceTicket.rootEpoch))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testStagedIncompleteResidentGraphReturnsTypedStructureCoverageWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let didPublish = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(didPublish)
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: sourceTicket.rootEpoch))
        let initialAccounting = await graph.accounting()
        let key = try XCTUnwrap(initialAccounting.currentObservedKey)
        let token = WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: sourceTicket.rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: key.catalogGeneration,
            ingressGeneration: sourceTicket.ingressGeneration,
            projectionInvalidationGeneration: 1
        )
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: token,
            repositoryAuthority: key.repositoryAuthority,
            contributionGeneration: key.contributionGeneration,
            schemaVersion: key.schemaVersion,
            policyVersion: key.policyVersion
        )
        let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: sourceTicket.rootEpoch.rootID,
            rootLifetimeID: sourceTicket.rootEpoch.rootLifetimeID,
            fileID: source.id,
            standardizedRootPath: loaded.standardizedFullPath,
            standardizedRelativePath: source.standardizedRelativePath,
            standardizedFullPath: source.standardizedFullPath
        ))
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let entry = WorkspaceCodemapProjectionEntry(
            identity: identity,
            requestGeneration: sourceTicket.requestGeneration,
            pathGeneration: sourceTicket.pathGeneration,
            pipelineIdentity: pipeline,
            outcome: .terminalExcluded(.securityExcluded)
        )
        let byteCount: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: [entry]
        ) {
        case let .success(value):
            byteCount = value
        case let .failure(error):
            return XCTFail("Unexpected projection byte accounting failure: \(error)")
        }
        let counts = WorkspaceCodemapProjectionCounts(
            supportedCandidateCount: 2,
            processedCandidateCount: 1,
            contributedCount: 0,
            emptyCount: 0,
            terminalArtifactCount: 0,
            terminalExcludedCount: 1,
            transientCount: 0
        )
        let progress = WorkspaceCodemapProjectionProgress(
            phase: .publishingProjectionSegment,
            counts: counts,
            catalogPageCount: 1,
            catalogPathByteCount: UInt64(source.standardizedRelativePath.utf8.count),
            publishedSegmentCount: 1,
            publishedSegmentByteCount: byteCount,
            catalogCompletion: nil
        )
        let segment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 0,
            entries: [entry],
            progress: progress,
            byteCount: byteCount
        ) {
        case let .success(value):
            segment = value
        case let .failure(error):
            return XCTFail("Unexpected projection segment failure: \(error)")
        }
        let segmentDisposition = await graph.applyProjectionSnapshot(.segment(segment))
        XCTAssertEqual(segmentDisposition, .accepted(progress))
        let stagedAccounting = await graph.accounting()
        XCTAssertEqual(stagedAccounting.publishedSummary?.nodeCount, 2)

        let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.incomplete(
            progress: progress,
            remainingCount: nil,
            retry: nil
        )
        let disposition = await store.queryCodemapStructureGraph(
            WorkspaceCodemapStructureTraversalQuery(
                seeds: [WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)],
                direction: .both,
                limits: .init(
                    maximumDepth: 2,
                    maximumNodeCount: 10,
                    maximumEdgeCount: 10,
                    maximumByteCount: 4096
                )
            )
        )
        XCTAssertEqual(
            disposition,
            .unavailable(.definitionUniverse(
                rootEpoch: sourceTicket.rootEpoch,
                coverage: coverage
            ))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testGraphQueryRejectsForeignEpochAndUnreadySourcesWithoutCrossRootTargets() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/ForeignReference.swift":
                    "struct ForeignReference { let value: SharedDefinition }\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/SharedDefinition.swift": "struct SharedDefinition {}\n"
            ]
        )
        XCTAssertEqual(firstRoot.lastPathComponent, secondRoot.lastPathComponent)

        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .engine
        )
        let projectionCatalogGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await projectionCatalogGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await projectionCatalogGate.enterAndWait(rootEpoch)
        }
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let projectionCatalogsBlocked = await projectionCatalogGate.waitUntilInvocationCount(2)
        XCTAssertTrue(projectionCatalogsBlocked)
        await projectionCatalogGate.release()
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: firstTicket
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: secondTicket
        )

        let firstOnly = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(firstOnly.roots.count, 1)
        let firstRootResult = try XCTUnwrap(firstOnly.roots.first)
        XCTAssertFalse(firstRootResult.result.targets.contains {
            $0.fileID == secondFile.id
        })
        XCTAssertTrue(firstRootResult.result.targets.allSatisfy {
            $0.rootEpoch == firstTicket.rootEpoch
        })

        let combined = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: secondTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(Set(combined.roots.map(\.rootEpoch)), [
            firstTicket.rootEpoch,
            secondTicket.rootEpoch
        ])
        for rootResult in combined.roots {
            XCTAssertTrue(rootResult.result.targets.allSatisfy {
                $0.rootEpoch == rootResult.rootEpoch
            })
            XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
                $0.source.rootEpoch == rootResult.rootEpoch &&
                    $0.target.rootEpoch == rootResult.rootEpoch
            })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)

        let foreign = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                    rootEpoch: secondTicket.rootEpoch,
                    ticket: firstTicket
                )
            ])
        )
        XCTAssertEqual(foreign, .unavailable(.foreignRootEpoch(firstFile.id)))

        let resolutionGate = CodemapResolutionGate()
        let pendingFixture = try CodemapStoreFixture(
            name: #function + "-pending",
            projectionAuthority: .none,
            resolutionGate: resolutionGate
        )
        let pendingProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await pendingFixture.shutdown()
        }
        let pendingStore = pendingFixture.makeStore(selectionGraphFactory: pendingProbe.factory)
        let pendingLoaded = try await pendingStore.loadRoot(path: firstRoot.path)
        let pendingFiles = await pendingStore.files(inRoot: pendingLoaded.id)
        let pendingFile = try XCTUnwrap(pendingFiles.first)
        let unreadyTicket = try await pendingTicket(
            pendingStore.requestCodemapArtifact(forFileID: pendingFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let unready = await pendingStore.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unreadyTicket)
            ])
        )
        XCTAssertEqual(unready, .unavailable(.sourceNotReady(pendingFile.id)))
        XCTAssertEqual(pendingProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: pendingStore, ticket: unreadyTicket)
        await pendingStore.unloadRoot(id: pendingLoaded.id)

        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testMultiRootGraphQueryEnforcesAggregateBudgetBeforeNPlusOneMaterialization() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let thirdRepository = try ReviewGitRepositoryFixture(name: #function + "-third")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "struct First { let value: MissingFirst }\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Source.swift": "struct Second { let value: MissingSecond }\n"]
        )
        let thirdRoot = try thirdRepository.makeRepository(
            named: "third",
            files: ["Sources/Source.swift": "struct Third { let value: MissingThird }\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .engine
        )
        let projectionCatalogGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await projectionCatalogGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
            thirdRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100,
                maximumByteCount: 521
            )
        )
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await projectionCatalogGate.enterAndWait(rootEpoch)
        }

        var loadedRoots: [WorkspaceRootRecord] = []
        var tickets: [WorkspaceCodemapArtifactDemandTicket] = []
        for root in [firstRoot, secondRoot, thirdRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let file = try XCTUnwrap(files.first)
            let ticket = try await pendingTicket(
                store.requestCodemapArtifact(forFileID: file.id)
            )
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            tickets.append(ticket)
        }
        let projectionCatalogsBlocked = await projectionCatalogGate.waitUntilInvocationCount(2)
        XCTAssertTrue(projectionCatalogsBlocked)
        await projectionCatalogGate.release()
        for ticket in tickets {
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: ticket
            )
        }

        let firstTwoQuery = WorkspaceCodemapStoreSelectionGraphQuery(
            selectedSources: tickets
                .prefix(2)
                .map(WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:))
        )
        let firstTwo = await store.queryCodemapSelectionGraph(firstTwoQuery)
        guard case let .readyPartial(firstTwoResult) = firstTwo else {
            return XCTFail("Expected the N-root query to fit the aggregate budget.")
        }
        XCTAssertEqual(firstTwoResult.roots.count, 2)
        XCTAssertEqual(
            firstTwoResult.roots.reduce(0) { $0 + $1.result.referenceFailures.count },
            2
        )
        let afterNMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNMaterializations, 2)

        let nPlusOneQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: tickets.map(
            WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:)
        ))
        let nPlusOne = await store.queryCodemapSelectionGraph(nPlusOneQuery)
        XCTAssertEqual(
            nPlusOne,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterNPlusOneMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNPlusOneMaterializations - afterNMaterializations, 2)

        let automaticSources = tickets.map {
            WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: $0.rootEpoch,
                fileID: $0.fileID,
                catalogGeneration: $0.catalogGeneration
            )
        }
        let beforeAutomaticN = await graphProbe.materializedQueryResultCount()
        let automaticN = try await store.resolveAutomaticCodemapSelection(
            sources: Array(automaticSources.prefix(2)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(automaticN.roots.count, 2)
        let afterAutomaticN = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticN - beforeAutomaticN, 2)

        let automaticNPlusOne = try await store.resolveAutomaticCodemapSelection(
            sources: automaticSources,
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(automaticNPlusOne.roots.isEmpty)
        XCTAssertTrue(automaticNPlusOne.targets.isEmpty)
        XCTAssertNil(automaticNPlusOne.publicationReceipt)
        XCTAssertEqual(
            automaticNPlusOne.aggregateCoverage,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterAutomaticNPlusOne = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticNPlusOne - afterAutomaticN, 2)

        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let buildGate = CodemapSelectionGraphBuildGate(autoReleaseTimeout: nil)
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        let firstSettled = try await settledResult(store: store, ticket: firstTicket)
        guard case .ready = firstSettled else {
            XCTFail("Expected first codemap artifact ready, got \(firstSettled)")
            throw CodemapStoreTestError.expectedReady
        }
        let blockedGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let isFailClosedQueuedState: (WorkspaceCodemapStoreSelectionGraphQueryDisposition) -> Bool = {
            disposition in
            switch disposition {
            case let .unavailable(.notActivated(rootEpoch)),
                 let .busy(.runtime(rootEpoch: rootEpoch, reason: .rebuilding)),
                 let .stale(.runtime(
                     rootEpoch: rootEpoch,
                     reason: .staleCurrentness(currentKey: _)
                 )):
                rootEpoch == firstTicket.rootEpoch
            default:
                false
            }
        }
        let queryClock = ContinuousClock()
        let initialQueryStarted = queryClock.now
        let whileInitialBuildQueued = await store.queryCodemapSelectionGraph(firstQuery)
        let initialQueryDuration = initialQueryStarted.duration(to: queryClock.now)
        XCTAssertEqual(
            whileInitialBuildQueued,
            .unavailable(.notActivated(firstTicket.rootEpoch))
        )
        XCTAssertLessThan(initialQueryDuration, .seconds(1))

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        let secondSettled = try await settledResult(store: store, ticket: secondTicket)
        guard case .ready = secondSettled else {
            XCTFail("Expected second codemap artifact ready, got \(secondSettled)")
            throw CodemapStoreTestError.expectedReady
        }
        let query = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let queryStarted = queryClock.now
        let whileNewerContributionQueued = await store.queryCodemapSelectionGraph(query)
        let queryDuration = queryStarted.duration(to: queryClock.now)
        XCTAssertTrue(
            isFailClosedQueuedState(whileNewerContributionQueued),
            "Expected queued latest-wins work to hide the older shard."
        )
        XCTAssertLessThan(queryDuration, .seconds(1))

        buildGate.release(generation: blockedGeneration)
        let latestGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: blockedGeneration)
        )
        let accountingBeforeUnload = await oldGraph.accounting()
        XCTAssertEqual(
            accountingBeforeUnload.currentObservedKey?.contributionGeneration.rawValue,
            latestGeneration
        )
        XCTAssertEqual(accountingBeforeUnload.currentUnavailableReason, .rebuilding)
        if let publishedSummary = accountingBeforeUnload.publishedSummary {
            XCTAssertLessThan(
                publishedSummary.key.contributionGeneration.rawValue,
                latestGeneration,
                "Expected any retained published shard to be stale while the latest generation remains blocked."
            )
        }
        let latestBlockedQueryStarted = queryClock.now
        let whileLatestContributionBlocked = await store.queryCodemapSelectionGraph(query)
        let latestBlockedQueryDuration = latestBlockedQueryStarted.duration(to: queryClock.now)
        XCTAssertTrue(
            isFailClosedQueuedState(whileLatestContributionBlocked),
            "Expected blocked latest-wins work to keep stale graph state fail closed."
        )
        XCTAssertLessThan(latestBlockedQueryDuration, .seconds(1))

        let unloadTask = Task {
            await store.unloadRoot(id: loaded.id)
        }
        let revocationDeadline = queryClock.now.advanced(by: .seconds(5))
        var afterRevocation = await store.queryCodemapSelectionGraph(query)
        while afterRevocation != .stale(.currentness(firstTicket.rootEpoch)),
              queryClock.now < revocationDeadline
        {
            XCTAssertTrue(
                isFailClosedQueuedState(afterRevocation),
                "Expected the blocked graph to remain fail closed while unload revocation completed."
            )
            await Task.yield()
            afterRevocation = await store.queryCodemapSelectionGraph(query)
        }
        XCTAssertEqual(afterRevocation, .stale(.currentness(firstTicket.rootEpoch)))
        buildGate.release(generation: latestGeneration)
        buildGate.releaseAll()
        await unloadTask.value

        let oldAccounting = await oldGraph.accounting()
        XCTAssertNil(oldAccounting.publishedSummary)
        XCTAssertEqual(
            oldAccounting.currentUnavailableReason,
            .explicitRootUnavailable(.rootUnloaded)
        )

        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFirst = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFirst.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        let reloadedPublished = await graphProbe.waitUntilPublished(
            rootEpoch: reloadedTicket.rootEpoch
        )
        XCTAssertTrue(reloadedPublished)
        XCTAssertNotEqual(reloadedTicket.rootEpoch, firstTicket.rootEpoch)
        let oldLifetimeQuery = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(oldLifetimeQuery, .stale(.currentness(firstTicket.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let blockerRoot = try repositoryFixture.makeRepository(
            named: "blocker",
            files: ["Sources/Blocker.swift": "struct Blocker {}\n"]
        )
        let selectionRoot = try repositoryFixture.makeRepository(
            named: "selection",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let buildGate = CodemapSelectionGraphBuildGate()
        let admissionWaitGate = CodemapSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe(
            buildGate: buildGate,
            admissionPolicy: .init(
                maximumActiveReservationCount: 1,
                maximumReservedBindingCount: 100_000
            ),
            processAdmissionWaitHook: {
                await admissionWaitGate.enterAndWait()
            }
        )
        addTeardownBlock {
            await admissionWaitGate.release()
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let blocker = try await store.loadRoot(path: blockerRoot.path)
        let selection = try await store.loadRoot(path: selectionRoot.path)

        let blockerFiles = await store.files(inRoot: blocker.id)
        let blockerFile = try XCTUnwrap(blockerFiles.first)
        let blockerTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: blockerFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: blockerTicket))
        let blockerGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())

        let selectionFiles = await store.files(inRoot: selection.id)
        let first = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let admissionWaitEntered = await admissionWaitGate.waitUntilEntered()
        XCTAssertTrue(admissionWaitEntered)
        let selectionGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstAccounting = await selectionGraph.accounting()
        let firstObservedKey = try XCTUnwrap(firstAccounting.currentObservedKey)

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let latestObservedKey = await graphProbe.waitUntilObservedKey(
            rootEpoch: firstTicket.rootEpoch,
            after: firstObservedKey.contributionGeneration
        )
        XCTAssertNotNil(latestObservedKey)
        // `waitUntilObservedKey` returns once the graph actor accepts the newer desired key,
        // before the store necessarily resumes from `observeDesiredKey` and installs its
        // matching desired key / pending snapshot.  The publication flight drains only after
        // `enqueueCodemapGraphSnapshot` returns, so wait for that store-side handoff before
        // releasing the admission gate that lets the blocked worker resume.
        let latestPublicationDrained = await waitForCodemapGraphPublicationDrain(
            store: store,
            rootEpoch: firstTicket.rootEpoch
        )
        XCTAssertTrue(latestPublicationDrained)

        await admissionWaitGate.release()
        buildGate.release(generation: blockerGeneration)
        buildGate.releaseAll()

        let latestPublished = await graphProbe.waitUntilPublished(
            rootEpoch: firstTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(latestPublished)
        let finalAccounting = await selectionGraph.accounting()
        XCTAssertEqual(finalAccounting.currentObservedKey, latestObservedKey)
        XCTAssertEqual(finalAccounting.publishedSummary?.key, latestObservedKey)
        // `publishedCount` is cumulative runtime accounting and can include an intermediate publication
        // under scheduler interleavings; this seam test verifies final currentness and worker coalescing.
        XCTAssertGreaterThanOrEqual(finalAccounting.publishedCount, 1)
        let operationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(operationCounts.graphWorkerStarts, 2)

        await store.unloadRoot(id: selection.id)
        await store.unloadRoot(id: blocker.id)
    }

    func testNonGitDemandBecomesTerminalWithoutSourceReadManifestBuildOrGraphWork() async throws {
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        let preflightCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let first = await store.requestCodemapArtifact(forFileID: file.id)
        let second = await store.requestCodemapArtifact(forFileID: file.id)
        assertNonGitTerminal(first)
        assertNonGitTerminal(second)
        XCTAssertEqual(preflightCount.value, 1)
        let firstOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(firstOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(firstOperationCounts.demandTasksCreated, 0)

        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        await assertNonGitTerminal(store.requestCodemapArtifact(forFileID: reloadedFile.id))
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        let reloadedOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(reloadedOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(reloadedOperationCounts.demandTasksCreated, 0)
        await store.unloadRoot(id: reloaded.id)
    }

    func testNonGitPresentationPlanStartsNoCodemapRuntimeDemandBuildOrCASWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(codemapGitEligibilityProbe: .production())
        _ = try await store.loadRoot(path: root.path)

        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: .selected,
            selection: StoredSelection(
                selectedPaths: ["Sources/Feature.swift"],
                codemapAutoEnabled: false
            ),
            store: store,
            rootScope: .allLoaded,
            profile: .uiAssisted
        )
        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(for: plan.intent, rootScope: .allLoaded)
        let merged = WorkspaceCodemapPresentationIntentResolver.merging(
            presentation,
            preflightIssues: plan.preflightIssues
        )

        XCTAssertTrue(merged.orderedEntries.isEmpty)
        XCTAssertTrue(merged.issues.contains {
            if case .unavailable(_, .gitTerminal(.nonGit)) = $0 { return true }
            return false
        })
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }
}
