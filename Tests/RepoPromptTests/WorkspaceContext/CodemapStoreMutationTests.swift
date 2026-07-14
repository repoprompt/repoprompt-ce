import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapStoreMutationTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testStoreEditRenameAndDeleteRevokeAuthorityBeforeReturningAndRecoverAfterRetainedInvalidation() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Mutable.swift": SwiftFixtureSource.emptyStruct("Mutable"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
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
        let initialFiles = await store.files(inRoot: loaded.id)
        let mutable = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Mutable.swift" })
        let unrelated = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let mutableTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: mutable.id))
        _ = try await readyResult(settledResult(store: store, ticket: mutableTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath,
            newContent: "struct Mutable { let edited = true }\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(mutableTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let editedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath
        )
        let editedFile = try XCTUnwrap(editedFileValue)
        let editedDemand = try await readyArtifactDemand(store: store, forFileID: editedFile.id)
        let editedTicket = editedDemand.ticket
        try await store.moveFile(
            rootID: loaded.id,
            from: mutable.standardizedRelativePath,
            to: "Sources/Renamed.swift"
        )
        await assertStale(store.codemapArtifactDemandStatus(editedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let renamedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: "Sources/Renamed.swift"
        )
        let renamedFile = try XCTUnwrap(renamedFileValue)
        let renamedDemand = try await readyArtifactDemand(store: store, forFileID: renamedFile.id)
        let renamedTicket = renamedDemand.ticket
        try await store.deleteFile(rootID: loaded.id, relativePath: "Sources/Renamed.swift")
        await assertStale(store.codemapArtifactDemandStatus(renamedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testCheckoutFencesOldAuthorityAndCreatePreservesUnrelatedSuccessorDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let initialDemand = try await readyArtifactDemand(store: store, forFileID: feature.id)
        let ticket = initialDemand.ticket
        let ready = initialDemand.ready
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        let service = WorkspaceCheckoutRefreshService(
            store: store,
            searchService: WorkspaceSearchService()
        )
        _ = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Checkout must revoke the retained presentation before returning.")
        }
        try await assertEngineRootCount(1, fixture: fixture)
        let oldGraphAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldGraphAccounting.activeRebuildCount, 0)

        let successorFileValue = await store.file(
            rootID: loaded.id,
            relativePath: feature.standardizedRelativePath
        )
        let successorFile = try XCTUnwrap(successorFileValue)
        let successorDemand = try await readyArtifactDemand(store: store, forFileID: successorFile.id)
        let successorTicket = successorDemand.ticket
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/CatalogReplacement.swift",
            content: SwiftFixtureSource.emptyStruct("CatalogReplacement")
        )
        guard case .ready = await store.codemapArtifactDemandStatus(successorTicket) else {
            return XCTFail("A path-local create must preserve unrelated ready codemap authority.")
        }
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAwaitsPresentationGraphAndEngineRevocationBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        await store.unloadRoot(id: loaded.id)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Unload must revoke the retained presentation before returning.")
        }
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.rootUnloaded))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        try await assertEngineRootCount(0, fixture: fixture)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            ticket.rootEpoch,
            feature.standardizedRelativePath
        )
        XCTAssertNil(route)
    }
}
