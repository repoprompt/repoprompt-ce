import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapWatcherFenceTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testCatalogAdvanceFencesPendingTicketAndExactRegistryRoute() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let routed = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(ticket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(routed?.identity.fileID, file.id)

        try Self.write("struct Added {}\n", to: root.appendingPathComponent("Sources/Added.swift"))
        let replayTask = Task {
            await store.ensureIndexedFiles(paths: [
                root.appendingPathComponent("Sources/Added.swift").path
            ])
        }

        await gate.release()
        _ = await replayTask.value
        await assertStale(store.codemapArtifactDemandStatus(ticket))

        let currentFiles = await store.files(inRoot: loaded.id)
        let currentFile = try XCTUnwrap(currentFiles.first {
            $0.standardizedRelativePath == file.standardizedRelativePath
        })
        let successorDemand = await store.requestCodemapArtifact(forFileID: currentFile.id)
        let successorTicket: WorkspaceCodemapArtifactDemandTicket
        switch successorDemand {
        case let .pending(ticket):
            successorTicket = ticket
        case let .ready(ready):
            successorTicket = ready.ticket
        case let .unavailable(reason):
            return XCTFail("Expected current successor demand, got \(reason)")
        }
        XCTAssertEqual(successorTicket.rootEpoch, ticket.rootEpoch)
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        XCTAssertNotEqual(successorTicket, ticket)
        let successorStatus = await store.codemapArtifactDemandStatus(successorTicket)
        if case .unavailable(.staleCurrentness) = successorStatus {
            XCTFail("Expected successor ticket to remain current")
        }
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        _ = await store.cancelCodemapArtifactDemand(successorTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testManifestCandidateAfterPathInvalidationUsesSuccessorPathGeneration() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))

        try Self.write(
            "struct Feature { let changed = true }\n",
            to: root.appendingPathComponent(file.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(file.standardizedRelativePath, nil)]
        )
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))

        let currentFileValue = await store.file(
            rootID: loaded.id,
            relativePath: file.standardizedRelativePath
        )
        let currentFile = try XCTUnwrap(currentFileValue)
        let successorDemand = await store.requestCodemapArtifact(forFileID: currentFile.id)
        let successorTicket: WorkspaceCodemapArtifactDemandTicket
        let successorResult: WorkspaceCodemapArtifactDemandResult
        switch successorDemand {
        case let .pending(ticket):
            successorTicket = ticket
            successorResult = try await settledResult(store: store, ticket: ticket)
        case let .ready(ready):
            successorTicket = ready.ticket
            successorResult = .ready(ready)
        case let .unavailable(reason):
            return XCTFail("Expected successor demand after path invalidation, got \(reason).")
        }
        XCTAssertGreaterThan(successorTicket.pathGeneration, firstTicket.pathGeneration)
        XCTAssertEqual(successorTicket.requestGeneration, successorTicket.pathGeneration)
        let routed = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            file.standardizedRelativePath
        )
        XCTAssertEqual(routed?.identity.fileID, file.id)
        XCTAssertEqual(routed?.requestGeneration, successorTicket.requestGeneration)
        XCTAssertEqual(routed?.pathGeneration, successorTicket.pathGeneration)
        XCTAssertEqual(routed?.ingressGeneration, successorTicket.ingressGeneration)
        let successorReady = try readyResult(successorResult)
        XCTAssertEqual(successorReady.snapshot.requestGeneration, successorTicket.requestGeneration)
        XCTAssertEqual(fixture.buildCount.value, 2)
        _ = await store.cancelCodemapArtifactDemand(successorTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAndReloadFenceOldLifetimeAndDrainCodemapRootState() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: root.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let unloadTask = Task {
            await store.unloadRoot(id: firstRoot.id)
        }
        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: firstTicket,
            relativePath: firstFile.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        await gate.release()
        await unloadTask.value

        let secondRoot = try await store.loadRoot(path: root.path)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )

        XCTAssertNotEqual(secondRoot.id, firstRoot.id)
        XCTAssertNotEqual(secondTicket.rootEpoch, firstTicket.rootEpoch)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        try await assertNonGitTerminal(settledResult(store: store, ticket: secondTicket))
        await store.unloadRoot(id: secondRoot.id)
        let engineRootCountIsZero = try await engineRootCountBecomesZero(fixture: fixture)
        XCTAssertTrue(engineRootCountIsZero)
    }

    func testReadyDemandsReuseInjectedRuntimeRegistryAndEngineSingletons() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let firstFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let secondFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        let secondReady = try await readyResult(
            settledResult(store: store, ticket: secondTicket)
        )

        XCTAssertEqual(firstTicket.rootEpoch, secondTicket.rootEpoch)
        XCTAssertEqual(firstReady.identity.fileID, firstFile.id)
        XCTAssertEqual(firstReady.snapshot.fileID, firstFile.id)
        XCTAssertEqual(try firstReady.handle.artifactKey(), firstReady.snapshot.artifactKey)
        XCTAssertEqual(secondReady.identity.fileID, secondFile.id)
        XCTAssertEqual(secondReady.snapshot.fileID, secondFile.id)
        XCTAssertEqual(try secondReady.handle.artifactKey(), secondReady.snapshot.artifactKey)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        XCTAssertTrue(try fixture.runtime().bindingIntegrationRegistry === fixture.registry)

        let firstCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                firstTicket.rootEpoch,
                firstFile.standardizedRelativePath
            )
        let secondCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                secondTicket.rootEpoch,
                secondFile.standardizedRelativePath
            )
        XCTAssertEqual(firstCandidate?.identity.fileID, firstFile.id)
        XCTAssertEqual(secondCandidate?.identity.fileID, secondFile.id)

        await store.unloadRoot(id: loaded.id)
        XCTAssertThrowsError(try firstReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try secondReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
    }

    func testCancellationAfterReadyRevokesRetainedHandleIdempotently() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        addTeardownBlock {
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
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )
        XCTAssertEqual(try ready.handle.artifactKey(), ready.snapshot.artifactKey)
        let retainCountBeforeCancellation = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(retainCountBeforeCancellation, 1)
        let cleanupBeforeCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupBeforeCancellation,
            .init(
                demandRecordPresent: true,
                bundlePresent: true,
                ownerCount: 0,
                liveOverlayPresent: true
            )
        )

        let firstCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(firstCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanupAfterFirstCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupAfterFirstCancellation,
            .init(
                demandRecordPresent: false,
                bundlePresent: false,
                ownerCount: 0,
                liveOverlayPresent: false
            )
        )

        let secondCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertFalse(secondCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanupAfterSecondCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupAfterSecondCancellation,
            cleanupAfterFirstCancellation
        )

        await store.unloadRoot(id: loaded.id)
    }

    func testFinalReadyRetainReleaseRemovesDemandBundleOwnerAndLiveOverlay() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
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
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )

        let released = await store.releaseReadyCodemapArtifactDemandRetain(ticket)
        XCTAssertTrue(released)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanup = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanup,
            .init(
                demandRecordPresent: false,
                bundlePresent: false,
                ownerCount: 0,
                liveOverlayPresent: false
            )
        )
        let releasedAgain = await store.releaseReadyCodemapArtifactDemandRetain(ticket)
        XCTAssertFalse(releasedAgain)
        await store.unloadRoot(id: loaded.id)
    }

    func testReadyCancellationCleanupCannotCancelSamePathSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let cancelledRequestIDs = CodemapLockedValues<UUID>()
        let cancellationGate = CodemapSuspensionGate()
        let successorPublicationGate = CodemapArmableSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await cancellationGate.release()
            await successorPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { ticket in
                guard cancelledRequestIDs.values.contains(ticket.requestID) else { return }
                await cancellationGate.enterAndWait()
            },
            readyPublicationHook: { _ in
                await successorPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let cancelledTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        cancelledRequestIDs.append(cancelledTicket.requestID)
        let cancelledReady = try await readyResult(
            settledResult(store: store, ticket: cancelledTicket)
        )
        let cancelledGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: cancelledTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(cancelledGraphPublished)
        let epochGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: cancelledTicket.rootEpoch))
        let cancelledGraphAccounting = await epochGraph.accounting()
        let cancelledGraphKey = try XCTUnwrap(cancelledGraphAccounting.currentObservedKey)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await successorPublicationGate.arm()

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(cancelledTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertCancelled(store.codemapArtifactDemandStatus(cancelledTicket))
        XCTAssertThrowsError(try cancelledReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }

        try Self.write(
            "struct Feature { let successorGeneration = true }\n",
            to: root.appendingPathComponent(file.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(file.standardizedRelativePath, nil)]
        )
        let refreshedFiles = await store.files(inRoot: loaded.id)
        let refreshedFile = try XCTUnwrap(refreshedFiles.first {
            $0.standardizedRelativePath == file.standardizedRelativePath
        })
        let successorTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: refreshedFile.id)
        )
        XCTAssertNotEqual(successorTicket, cancelledTicket)
        XCTAssertNotEqual(successorTicket.requestID, cancelledTicket.requestID)
        XCTAssertNotEqual(successorTicket.retainID, cancelledTicket.retainID)
        XCTAssertEqual(successorTicket.rootEpoch, cancelledTicket.rootEpoch)
        XCTAssertEqual(successorTicket.fileID, cancelledTicket.fileID)
        XCTAssertGreaterThan(successorTicket.requestGeneration, cancelledTicket.requestGeneration)
        XCTAssertGreaterThan(successorTicket.pathGeneration, cancelledTicket.pathGeneration)
        let successorPublicationEntered = await successorPublicationGate.waitUntilEntered()
        XCTAssertTrue(successorPublicationEntered)

        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)
        let gatedSuccessor = await store.codemapArtifactDemandCleanupSnapshotForTesting(successorTicket)
        XCTAssertTrue(gatedSuccessor.demandRecordPresent)
        XCTAssertTrue(gatedSuccessor.liveOverlayPresent)
        await successorPublicationGate.release()
        let successorReady = try await readyResult(
            settledResult(store: store, ticket: successorTicket)
        )
        XCTAssertEqual(successorReady.ticket, successorTicket)
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        let survivingReady = try await readyResult(
            store.codemapArtifactDemandStatus(successorTicket)
        )
        XCTAssertEqual(try survivingReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        let successorGraphKey = await graphProbe.waitUntilObservedKey(
            rootEpoch: successorTicket.rootEpoch,
            after: cancelledGraphKey.contributionGeneration
        )
        XCTAssertNotNil(successorGraphKey)
        XCTAssertTrue(graphProbe.graph(rootEpoch: successorTicket.rootEpoch) === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        XCTAssertNotEqual(reloadedTicket.rootEpoch, successorTicket.rootEpoch)
        let reloadedGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: reloadedTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(reloadedGraphPublished)
        let reloadedGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: reloadedTicket.rootEpoch))
        XCTAssertFalse(reloadedGraph === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        await store.unloadRoot(id: reloaded.id)
    }

    func testWatcherRenamePairFencesOnlyOldAndNewPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Old.swift": "struct Old {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let old = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Old.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let oldTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: old.id))
        let oldReady = try await readyResult(settledResult(store: store, ticket: oldTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: unrelatedTicket
        )
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        let unrelatedQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
        ])
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent(old.standardizedRelativePath),
            to: root.appendingPathComponent("Sources/New.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [
                .fileRemoved(old.standardizedRelativePath),
                .fileAdded("Sources/New.swift")
            ]
        )

        await assertStale(store.codemapArtifactDemandStatus(oldTicket))
        XCTAssertThrowsError(try oldReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        let renamedValue = await store.file(rootID: loaded.id, relativePath: "Sources/New.swift")
        let renamed = try XCTUnwrap(renamedValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamed.id))
        XCTAssertGreaterThan(renamedTicket.pathGeneration, oldTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: renamedTicket
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: renamedTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testPathRepairPublishesReadyContributionCompletedDuringRebuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "struct Affected {}\n",
                "Sources/Late.swift": "struct Late { let survivor: Survivor }\n",
                "Sources/Survivor.swift": "struct Survivor {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let buildGate = CodemapSelectionGraphBuildGate()
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let late = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Late.swift" })
        let survivor = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Survivor.swift" })
        let survivorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: survivor.id))
        let survivorReady = try await readyResult(settledResult(store: store, ticket: survivorTicket))
        let initialGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        buildGate.release(generation: initialGeneration)
        let initialGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: survivorTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(initialGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: survivorTicket,
            contributionsByFileID: [
                survivor.id: CodeMapSelectionGraphContribution(
                    artifactKey: survivorReady.snapshot.artifactKey,
                    definitions: ["Survivor"],
                    references: []
                )
            ]
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: survivorTicket
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: survivorTicket)
            ])
        )

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        let repairTask = Task {
            await store.replayObservedFileSystemDeltas(
                rootID: loaded.id,
                deltas: [.fileModified(affected.standardizedRelativePath, nil)]
            )
        }
        let repairGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: initialGeneration)
        )

        let lateTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: late.id))
        let lateReady = try await readyResult(settledResult(store: store, ticket: lateTicket))
        buildGate.release(generation: repairGeneration)
        buildGate.releaseAll()
        await repairTask.value
        let repairedGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: lateTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(repairedGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: lateTicket,
            contributionsByFileID: [
                late.id: CodeMapSelectionGraphContribution(
                    artifactKey: lateReady.snapshot.artifactKey,
                    definitions: ["Late"],
                    references: ["Survivor"]
                ),
                survivor.id: CodeMapSelectionGraphContribution(
                    artifactKey: survivorReady.snapshot.artifactKey,
                    definitions: ["Survivor"],
                    references: []
                )
            ]
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: lateTicket
        )

        let result = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: lateTicket)
            ])
        )
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertTrue(rootResult.result.sourceCoverage.contains {
            $0.source.fileID == late.id && $0.state == .covered
        })
        XCTAssertTrue(rootResult.result.targets.contains {
            $0.fileID == survivor.id
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherModifyDeleteAndGapAwaitPresentationGraphAndEngineFences() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "func affected() {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphFactory: graphProbe.factory
        )

        func requireReadyDemand(
            _ ticket: WorkspaceCodemapArtifactDemandTicket,
            phase: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> WorkspaceCodemapArtifactDemandReady {
            let result = try await settledResult(store: store, ticket: ticket)
            guard case let .ready(ready) = result else {
                XCTFail("Expected \(phase) ready, got \(result).", file: file, line: line)
                throw CodemapStoreTestError.expectedReady
            }
            return ready
        }

        func withReadyProjectionDemand<Value>(
            sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
            phase: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            body: (WorkspaceCodemapProjectionDemandTicket) async throws -> Value
        ) async throws -> Value {
            let projectionTicket = try await requireReadyProjectionDemand(
                store: store,
                sourceTickets: sourceTickets,
                phase: phase,
                file: file,
                line: line
            )
            do {
                let value = try await body(projectionTicket)
                await assertProjectionDemandReleased(
                    store: store,
                    projectionTicket,
                    phase: phase,
                    file: file,
                    line: line
                )
                return value
            } catch {
                _ = await store.releaseCodemapProjectionDemand(projectionTicket)
                throw error
            }
        }

        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let affectedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        let affectedReady = try await requireReadyDemand(
            affectedTicket,
            phase: "initial affected demand"
        )
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await requireReadyDemand(
            unrelatedTicket,
            phase: "initial unrelated demand"
        )
        let (unrelatedPresentation, graph) = try await withReadyProjectionDemand(
            sourceTickets: [affectedTicket, unrelatedTicket],
            phase: "initial affected/unrelated projection demand"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: unrelatedTicket
            )
            let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "Workspace",
                standardizedRelativePath: unrelated.standardizedRelativePath
            ))
            let unrelatedPresentation = try await frozenPresentationBundle(
                store.freezeCodemapPresentation([
                    WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
                ])
            )
            _ = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: affectedTicket),
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
                ])
            )
            let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: affectedTicket.rootEpoch))
            return (unrelatedPresentation, graph)
        }

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(affected.standardizedRelativePath, nil)]
        )

        await assertStale(store.codemapArtifactDemandStatus(affectedTicket))
        XCTAssertThrowsError(try affectedReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        XCTAssertGreaterThan(successorTicket.pathGeneration, affectedTicket.pathGeneration)
        let successorReady = try await requireReadyDemand(
            successorTicket,
            phase: "successor affected demand after modification"
        )
        let successorPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: affected.standardizedRelativePath
        ))
        let successorPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: successorTicket, logicalPath: successorPath)
            ])
        )
        try await withReadyProjectionDemand(
            sourceTickets: [successorTicket, unrelatedTicket],
            phase: "successor affected/unrelated projection demand after modification"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: successorTicket
            )
            let successorGraph = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket),
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
                ])
            )
            XCTAssertEqual(successorGraph.roots.first?.rootEpoch, successorTicket.rootEpoch)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(unrelated.standardizedRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileRemoved(unrelated.standardizedRelativePath)]
        )
        await assertStale(store.codemapArtifactDemandStatus(unrelatedTicket))
        XCTAssertThrowsError(try unrelatedReady.handle.artifactKey())
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(successorPresentation)
        )
        try await withReadyProjectionDemand(
            sourceTickets: [successorTicket],
            phase: "post-delete successor projection demand"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: successorTicket
            )
            let postDeleteSuccessorGraph = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket)
                ])
            )
            let postDeleteRoot = try XCTUnwrap(postDeleteSuccessorGraph.roots.first)
            XCTAssertEqual(postDeleteRoot.rootEpoch, successorTicket.rootEpoch)
            XCTAssertTrue(postDeleteRoot.result.sourceCoverage.contains {
                $0.source.fileID == affected.id && $0.state == .covered
            })
        }

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: successorTicket.rootEpoch.rootLifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.authorityRevoked))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            affected.standardizedRelativePath
        )
        XCTAssertNil(route)
        await store.unloadRoot(id: loaded.id)
    }
}
