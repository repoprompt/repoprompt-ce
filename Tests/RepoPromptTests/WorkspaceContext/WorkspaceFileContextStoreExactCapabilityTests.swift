@testable import RepoPromptApp
import XCTest

final class WorkspaceFileContextStoreExactCapabilityTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()
    private var stores: [WorkspaceFileContextStore] = []

    override func tearDown() async throws {
        for store in stores {
            let roots = await store.rootRefs(scope: .allLoaded)
            for root in roots {
                await store.unloadRoot(id: root.id)
            }
        }
        stores.removeAll()
        temporaryRoots.removeAll()
        try await super.tearDown()
    }

    private func makeStore() -> WorkspaceFileContextStore {
        let store = WorkspaceFileContextStore()
        stores.append(store)
        return store
    }

    func testExactCatalogCapabilityRequiresRootIdentityKindAndCatalogMembership() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "ExactCatalogCapability")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let cataloged = gitDataRoot.appendingPathComponent("repos/repo-key/snapshot/MAP.txt")
        let ignored = gitDataRoot.appendingPathComponent("ignored.txt")
        try FileSystemTestSupport.write("ignored.txt\n", to: gitDataRoot.appendingPathComponent(".gitignore"))
        try FileSystemTestSupport.write("map", to: cataloged)
        try FileSystemTestSupport.write("must not materialize", to: ignored)

        let store = makeStore()
        let loaded = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let exactRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let exactRoot = try XCTUnwrap(exactRootValue)

        XCTAssertEqual(exactRoot.id, loaded.id)
        let wrongKindRoot = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .primaryWorkspace
        )
        let wrongPathRoot = await store.exactRootRef(
            path: workspace.path,
            kind: .workspaceGitData
        )
        XCTAssertNil(wrongKindRoot)
        XCTAssertNil(wrongPathRoot)

        let recordValue = await store.exactCatalogFile(
            absolutePath: cataloged.path,
            expectedRoot: exactRoot,
            expectedKind: .workspaceGitData
        )
        let record = try XCTUnwrap(recordValue)
        let content = await store.readExactCatalogFile(record, expectedRoot: exactRoot)
        XCTAssertEqual(content, "map")

        let ignoredRecord = await store.exactCatalogFile(
            absolutePath: ignored.path,
            expectedRoot: exactRoot,
            expectedKind: .workspaceGitData
        )
        XCTAssertNil(
            ignoredRecord,
            "An on-disk ignored file must not be materialized by the exact capability"
        )

        let forgedRoot = WorkspaceRootRef(
            id: UUID(),
            name: exactRoot.name,
            fullPath: exactRoot.fullPath
        )
        let forgedRecord = await store.exactCatalogFile(
            absolutePath: cataloged.path,
            expectedRoot: forgedRoot,
            expectedKind: .workspaceGitData
        )
        let forgedContent = await store.readExactCatalogFile(record, expectedRoot: forgedRoot)
        XCTAssertNil(forgedRecord)
        XCTAssertNil(forgedContent)
    }

    func testExactCatalogCapabilityRejectsStaleRootLifetime() async throws {
        let workspace = try temporaryRoots.makeRoot(suiteName: "ExactCatalogLifetime")
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let artifact = gitDataRoot.appendingPathComponent("repos/repo-key/snapshot/MAP.txt")
        try FileSystemTestSupport.write("map", to: artifact)

        let store = makeStore()
        let first = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let frozenRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let frozenRoot = try XCTUnwrap(frozenRootValue)
        let frozenFileValue = await store.exactCatalogFile(
            absolutePath: artifact.path,
            expectedRoot: frozenRoot,
            expectedKind: .workspaceGitData
        )
        let frozenFile = try XCTUnwrap(frozenFileValue)

        await store.unloadRoot(id: first.id)
        let second = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)

        XCTAssertNotEqual(second.id, frozenRoot.id)
        let staleRecord = await store.exactCatalogFile(
            absolutePath: artifact.path,
            expectedRoot: frozenRoot,
            expectedKind: .workspaceGitData
        )
        let staleContent = await store.readExactCatalogFile(
            frozenFile,
            expectedRoot: frozenRoot
        )
        XCTAssertNil(staleRecord)
        XCTAssertNil(staleContent)
    }

    func testContextBuilderExactCandidateResolvesOnlyAuthorizedWorktreeContent() async throws {
        let logicalRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderExactLogical")
        let worktreeRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderExactWorktree")
        let siblingRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderExactSibling")
        let relativePath = "Sources/BranchOnly.swift"
        let canonicalFile = logicalRoot.appendingPathComponent(relativePath)
        let seedFile = worktreeRoot.appendingPathComponent("Sources/Seed.swift")
        let siblingFile = siblingRoot.appendingPathComponent(relativePath)
        try FileSystemTestSupport.write("canonical", to: canonicalFile)
        try FileSystemTestSupport.write("seed", to: seedFile)
        try FileSystemTestSupport.write("sibling", to: siblingFile)

        let store = makeStore()
        let fixture = try await makeSessionAuthorization(
            store: store,
            logicalRoot: logicalRoot,
            worktreeRoot: worktreeRoot
        )
        let worktreeOnlyFile = worktreeRoot.appendingPathComponent(relativePath)
        try FileSystemTestSupport.write("branch only", to: worktreeOnlyFile)
        let symlink = worktreeRoot.appendingPathComponent("Sources/CanonicalLink.swift")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: canonicalFile)

        let resolved = try await store.resolveContextBuilderSelectionCandidate(
            path: worktreeOnlyFile.path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        guard case let .resolved(files, route) = resolved else {
            return XCTFail("Expected exact worktree-only resolution, got \(resolved)")
        }
        XCTAssertEqual(route, .materializedFile)
        XCTAssertEqual(files.map(\.standardizedFullPath), [worktreeOnlyFile.standardizedFileURL.path])
        XCTAssertEqual(files.map(\.rootID), [fixture.authorization.root.id])

        let folder = try await store.resolveContextBuilderSelectionCandidate(
            path: worktreeRoot.appendingPathComponent("Sources").path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        guard case let .resolved(folderFiles, folderRoute) = folder else {
            return XCTFail("Expected exact folder expansion, got \(folder)")
        }
        XCTAssertEqual(folderRoute, .catalogFolder)
        XCTAssertEqual(
            Set(folderFiles.map(\.standardizedRelativePath)),
            ["Sources/BranchOnly.swift", "Sources/Seed.swift"]
        )

        let rootFolder = try await store.resolveContextBuilderSelectionCandidate(
            path: worktreeRoot.path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        guard case let .resolved(rootFiles, rootRoute) = rootFolder else {
            return XCTFail("Expected exact authorized root expansion, got \(rootFolder)")
        }
        XCTAssertEqual(rootRoute, .catalogFolder)
        XCTAssertEqual(
            Set(rootFiles.map(\.standardizedRelativePath)),
            ["Sources/BranchOnly.swift", "Sources/Seed.swift"]
        )

        let canonicalResult = try await store.resolveContextBuilderSelectionCandidate(
            path: canonicalFile.path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        let siblingResult = try await store.resolveContextBuilderSelectionCandidate(
            path: siblingFile.path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        let symlinkResult = try await store.resolveContextBuilderSelectionCandidate(
            path: symlink.path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        XCTAssertEqual(canonicalResult, .blockedOrAmbiguous(.outsideAuthorizedRoot))
        XCTAssertEqual(siblingResult, .blockedOrAmbiguous(.outsideAuthorizedRoot))
        XCTAssertEqual(symlinkResult, .blockedOrAmbiguous(.symbolicLink))
    }

    func testContextBuilderExactCandidateClassifiesReleasedAndReplacedRootAsStale() async throws {
        let logicalRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderStaleLogical")
        let worktreeRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderStaleWorktree")
        let relativePath = "Sources/Target.swift"
        try FileSystemTestSupport.write(
            "canonical",
            to: logicalRoot.appendingPathComponent(relativePath)
        )
        try FileSystemTestSupport.write(
            "worktree",
            to: worktreeRoot.appendingPathComponent(relativePath)
        )

        let store = makeStore()
        let fixture = try await makeSessionAuthorization(
            store: store,
            logicalRoot: logicalRoot,
            worktreeRoot: worktreeRoot
        )
        await store.releaseSessionWorktreeOwnership(ownerID: fixture.sessionID)
        let replacement = try await store.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        XCTAssertNotEqual(replacement.id, fixture.authorization.root.id)

        let result = try await store.resolveContextBuilderSelectionCandidate(
            path: worktreeRoot.appendingPathComponent(relativePath).path,
            authorization: fixture.authorization,
            folderPolicy: .expandFolders
        )
        guard case .staleAuthority = result else {
            return XCTFail("Expected stale authority, got \(result)")
        }
    }

    #if DEBUG
        func testContextBuilderExactCandidateClassifiesReplacementDuringEligibilityAsStale() async throws {
            let logicalRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderRaceLogical")
            let worktreeRoot = try temporaryRoots.makeRoot(suiteName: "ContextBuilderRaceWorktree")
            let store = makeStore()
            let fixture = try await makeSessionAuthorization(
                store: store,
                logicalRoot: logicalRoot,
                worktreeRoot: worktreeRoot
            )
            let worktreeOnlyFile = worktreeRoot.appendingPathComponent("Sources/Raced.swift")
            try FileSystemTestSupport.write("raced", to: worktreeOnlyFile)

            let gate = ContextBuilderCandidateGate()
            await store.setContextBuilderSelectionCandidateEligibilityDidResolveHandler { rootID in
                guard rootID == fixture.authorization.root.id else { return }
                await gate.enterAndWait()
            }
            defer {
                Task {
                    await store.setContextBuilderSelectionCandidateEligibilityDidResolveHandler(nil)
                }
            }

            let resolutionTask = Task {
                try await store.resolveContextBuilderSelectionCandidate(
                    path: worktreeOnlyFile.path,
                    authorization: fixture.authorization,
                    folderPolicy: .expandFolders
                )
            }
            let gateEntered = await gate.waitUntilEntered()
            XCTAssertTrue(gateEntered)
            await store.releaseSessionWorktreeOwnership(ownerID: fixture.sessionID)
            let replacement = try await store.loadRoot(
                path: worktreeRoot.path,
                kind: .sessionWorktree
            )
            XCTAssertNotEqual(replacement.id, fixture.authorization.root.id)
            await gate.release()

            let result = try await resolutionTask.value
            guard case .staleAuthority = result else {
                return XCTFail("Expected stale authority after replacement, got \(result)")
            }
            await store.setContextBuilderSelectionCandidateEligibilityDidResolveHandler(nil)
        }
    #endif

    private func makeSessionAuthorization(
        store: WorkspaceFileContextStore,
        logicalRoot: URL,
        worktreeRoot: URL
    ) async throws -> (sessionID: UUID, authorization: WorkspaceSessionRootAuthorization) {
        _ = try await store.loadRoot(path: logicalRoot.path, kind: .primaryWorkspace)
        let sessionID = UUID()
        let binding = AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: "repo-id",
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: UUID().uuidString,
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/exact-candidate",
            source: "test"
        )
        let projectionValue = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [binding]
        )
        let projection = try XCTUnwrap(projectionValue)
        let boundRoot = try XCTUnwrap(projection.boundRootsForMetadata.first)
        return try (sessionID, XCTUnwrap(boundRoot.sessionRootAuthorization))
    }
}

#if DEBUG
    private typealias ContextBuilderCandidateGate = TestReleaseFence
#endif
