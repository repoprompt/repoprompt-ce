import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRootBindingProjectionTests: XCTestCase {
    func testSingleBoundRootProjectsRelativeAndLogicalPathsToWorktree() {
        let logicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: "/repo/project"
        )
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: "/tmp/worktrees/project-agent"
        )
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )

        XCTAssertEqual(
            projection.translateInputPath("Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("/repo/project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("Project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("/tmp/worktrees/project-agent/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.projectedLogicalDisplayPath(forPhysicalPath: "/tmp/worktrees/project-agent/Sources/App.swift"),
            "Sources/App.swift"
        )
        XCTAssertNil(projection.projectedLogicalDisplayPath(forPhysicalPath: "/repo/project/Sources/App.swift"))
    }

    func testSingleBoundRootDoesNotStealUnboundRootAlias() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let docsRoot = WorkspaceRootRef(id: UUID(), name: "Docs", fullPath: "/repo/docs")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)],
            visibleLogicalRoots: [logicalRoot, docsRoot]
        )

        XCTAssertEqual(projection.translateInputPath("Docs/README.md"), "Docs/README.md")
        XCTAssertEqual(
            projection.translateInputPath("Project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.projectedLogicalDisplayPath(forPhysicalPath: "/tmp/worktrees/project-agent/Sources/App.swift"),
            "Project/Sources/App.swift"
        )
    }

    func testBoundRootsForMetadataAreDeterministicallySorted() {
        let firstLogical = WorkspaceRootRef(id: UUID(), name: "A", fullPath: "/repo/a")
        let secondLogical = WorkspaceRootRef(id: UUID(), name: "B", fullPath: "/repo/b")
        let firstPhysical = WorkspaceRootRef(id: UUID(), name: "A", fullPath: "/tmp/wt/a")
        let secondPhysical = WorkspaceRootRef(id: UUID(), name: "B", fullPath: "/tmp/wt/b")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(logicalRoot: secondLogical, physicalRoot: secondPhysical, binding: Self.binding(logicalRoot: secondLogical, physicalRoot: secondPhysical, worktreeID: "wt-b")),
                .init(logicalRoot: firstLogical, physicalRoot: firstPhysical, binding: Self.binding(logicalRoot: firstLogical, physicalRoot: firstPhysical, worktreeID: "wt-a"))
            ]
        )

        XCTAssertEqual(projection.boundRootsForMetadata.map(\.logicalRoot.standardizedFullPath), ["/repo/a", "/repo/b"])
        XCTAssertEqual(projection.boundRootsForMetadata.map(\.binding.worktreeID), ["wt-a", "wt-b"])
    }

    func testWorktreeScopeMetadataUsesBindingWorktreeNameForEffectiveName() throws {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            worktreeName: "project-agent",
            branch: "feature/demo",
            visualLabel: "Demo Worktree",
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )

        let scope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let mapping = try XCTUnwrap(scope.rootMappings.first)
        let logicalLabel = try XCTUnwrap(WorkspaceLogicalRootIdentity.labels(
            for: [
                WorkspaceLogicalRootIdentity.RootDescriptor(
                    physicalRootID: physicalRoot.id,
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: logicalRoot.id,
                        rootLifetimeID: physicalRoot.id
                    ),
                    preferredName: logicalRoot.name
                )
            ]
        )[physicalRoot.id])
        XCTAssertEqual(scope.kind, "session_bound_worktree")
        XCTAssertEqual(mapping.logicalRootName, logicalLabel)
        XCTAssertEqual(mapping.logicalRootPath, logicalLabel)
        XCTAssertEqual(mapping.effectiveRootName, "project-agent")
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
        XCTAssertEqual(mapping.worktreeID, "wt-1")
        XCTAssertEqual(mapping.branch, "feature/demo")
        XCTAssertEqual(mapping.label, "Demo Worktree")
    }

    func testDuplicateLogicalRootBasenamesProduceStableUniqueNonPhysicalLabels() throws {
        let reusedRootID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        let firstLifetimeID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001"))
        let secondLifetimeID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))
        let firstEpoch = WorkspaceCodemapRootEpoch(
            rootID: reusedRootID,
            rootLifetimeID: firstLifetimeID
        )
        let secondEpoch = WorkspaceCodemapRootEpoch(
            rootID: reusedRootID,
            rootLifetimeID: secondLifetimeID
        )
        let priorGeneratedLabel = WorkspaceLogicalRootIdentity.label(for: firstEpoch)
        let firstLogical = WorkspaceRootRef(id: UUID(), name: "repo", fullPath: "/canonical/one/repo")
        let secondLogical = WorkspaceRootRef(
            id: UUID(),
            name: priorGeneratedLabel,
            fullPath: "/canonical/two/repo"
        )
        let firstPhysical = WorkspaceRootRef(id: UUID(), name: "secret-one", fullPath: "/private/worktrees/secret-one")
        let secondPhysical = WorkspaceRootRef(
            id: UUID(),
            name: priorGeneratedLabel,
            fullPath: "/private/worktrees/secret-two"
        )
        let repeatedEpochPhysical = WorkspaceRootRef(
            id: UUID(),
            name: "secret-three",
            fullPath: "/private/worktrees/secret-three"
        )
        let descriptors = [
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: firstPhysical.id,
                rootEpoch: firstEpoch,
                preferredName: "repo"
            ),
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: secondPhysical.id,
                rootEpoch: secondEpoch,
                preferredName: priorGeneratedLabel
            ),
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: repeatedEpochPhysical.id,
                rootEpoch: firstEpoch,
                preferredName: "repo"
            )
        ]

        let first = WorkspaceLogicalRootIdentity.labels(for: descriptors)
        let second = WorkspaceLogicalRootIdentity.labels(for: Array(descriptors.reversed()))

        XCTAssertEqual(first, second)
        let firstLabel = "root@aaaaaaaa-0000-0000-0000-000000000001+bbbbbbbb-0000-0000-0000-000000000001"
        let secondLabel = "root@aaaaaaaa-0000-0000-0000-000000000001+bbbbbbbb-0000-0000-0000-000000000002"
        XCTAssertEqual(first[firstPhysical.id], firstLabel)
        XCTAssertEqual(first[repeatedEpochPhysical.id], firstLabel)
        XCTAssertEqual(first[secondPhysical.id], secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertEqual(priorGeneratedLabel, firstLabel)
        let logicalPaths = try [firstPhysical.id, secondPhysical.id].map { physicalRootID in
            try XCTUnwrap(try WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: XCTUnwrap(first[physicalRootID]),
                standardizedRelativePath: "Sources/App.swift"
            )).displayPath
        }.sorted()
        XCTAssertEqual(
            logicalPaths,
            [
                "\(firstLabel)/Sources/App.swift",
                "\(secondLabel)/Sources/App.swift"
            ]
        )
        XCTAssertFalse(first.values.contains { $0.contains("/canonical/") || $0.contains("/private/") })

        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: secondLogical,
                    physicalRoot: secondPhysical,
                    binding: Self.binding(
                        logicalRoot: secondLogical,
                        physicalRoot: secondPhysical,
                        worktreeID: "two"
                    )
                ),
                .init(
                    logicalRoot: firstLogical,
                    physicalRoot: firstPhysical,
                    binding: Self.binding(
                        logicalRoot: firstLogical,
                        physicalRoot: firstPhysical,
                        worktreeID: "one"
                    )
                )
            ]
        )
        let scope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(scope), encoding: .utf8))
        XCTAssertEqual(Set(scope.rootMappings.map(\.logicalRootName)).count, 2)
        XCTAssertFalse(encoded.contains(firstPhysical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(secondPhysical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(firstLogical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(secondLogical.standardizedFullPath))
    }

    func testFileTreeSnapshotIsDisplayedAsLogicalRoot() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )
        let rootID = UUID()
        let childID = UUID()
        let snapshot = FileTreeSelectionSnapshot(
            roots: [
                FileTreeFolderSnapshot(
                    id: rootID,
                    name: "project-agent",
                    fullPath: "/tmp/worktrees/project-agent",
                    standardizedFullPath: "/tmp/worktrees/project-agent",
                    standardizedRootPath: "/tmp/worktrees/project-agent",
                    children: [
                        .folder(FileTreeFolderSnapshot(
                            id: childID,
                            name: "Sources",
                            fullPath: "/tmp/worktrees/project-agent/Sources",
                            standardizedFullPath: "/tmp/worktrees/project-agent/Sources",
                            standardizedRootPath: "/tmp/worktrees/project-agent",
                            children: []
                        ))
                    ]
                )
            ],
            selectedFileIDs: [],
            mode: "full",
            showFullPaths: false,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: false
        )

        let logicalized = projection.logicalizeFileTreeSnapshot(snapshot)

        XCTAssertEqual(logicalized.roots.first?.name, "Project")
        XCTAssertEqual(logicalized.roots.first?.standardizedFullPath, "/repo/project")
        XCTAssertEqual(logicalized.roots.first?.standardizedRootPath, "/repo/project")
        guard case let .folder(child)? = logicalized.roots.first?.children.first else {
            return XCTFail("Expected logicalized child folder")
        }
        XCTAssertEqual(child.standardizedFullPath, "/repo/project/Sources")
        XCTAssertEqual(child.standardizedRootPath, "/repo/project")
    }

    func testSelectionCanPhysicalizeForLookupThenLogicalizeForPersistence() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "wt-1")
                )
            ]
        )
        let logicalSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            manualCodemapPaths: ["Sources/Manual.swift"],
            slices: ["Sources/Sliced.swift": [LineRange(start: 3, end: 9)]],
            codemapAutoEnabled: false
        )

        let physicalSelection = projection.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, ["/tmp/worktrees/project-agent/Sources/App.swift"])
        XCTAssertEqual(
            physicalSelection.manualCodemapPaths,
            ["/tmp/worktrees/project-agent/Sources/Manual.swift"]
        )
        XCTAssertEqual(
            physicalSelection.slices["/tmp/worktrees/project-agent/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
        )

        let persistedSelection = projection.logicalizeSelection(physicalSelection)
        XCTAssertEqual(persistedSelection.selectedPaths, ["/repo/project/Sources/App.swift"])
        XCTAssertEqual(
            persistedSelection.manualCodemapPaths,
            ["/repo/project/Sources/Manual.swift"]
        )
        XCTAssertEqual(
            persistedSelection.slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
        )

        let mixedAliasSelection = StoredSelection(
            selectedPaths: [
                "/repo/project/Sources/Sliced.swift",
                "/tmp/worktrees/project-agent/Sources/Sliced.swift"
            ],
            slices: [
                "/repo/project/Sources/Sliced.swift": [LineRange(start: 1, end: 20)],
                "/tmp/worktrees/project-agent/Sources/Sliced.swift": [LineRange(start: 5, end: 25)]
            ]
        )
        XCTAssertEqual(
            projection.logicalizeSelection(mixedAliasSelection).slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 1, end: 25)]
        )
        XCTAssertEqual(
            projection.physicalizeSelection(mixedAliasSelection).slices["/tmp/worktrees/project-agent/Sources/Sliced.swift"],
            [LineRange(start: 1, end: 25)]
        )
    }

    func testMaterializerFailsClosedWhenPhysicalRootCannotBeLoaded() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionLogical")
        try write("let origin = \"base\"\n", to: logicalRootURL.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        // Reusing the already-loaded logical root as the bound physical root forces
        // `.sessionWorktree` materialization to fail with a different root configuration.
        let unloadablePhysicalRoot = logicalRootURL
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: logicalRoot.name,
            fullPath: unloadablePhysicalRoot.path
        )
        let binding = Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "missing")

        let sessionID = UUID()
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [binding]
        )
        let visibleLookup = await store.lookupPath("Sources/App.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()

        let failClosedProjection = try XCTUnwrap(materializedProjection)
        let scopedLookup = await store.lookupPath(
            "Sources/App.swift",
            profile: .uiAssisted,
            rootScope: failClosedProjection.lookupRootScope
        )
        let scopeAvailability = await store.rootScopeAvailability(failClosedProjection.lookupRootScope)
        let catalogAccess = await store.searchCatalogAccess(rootScope: failClosedProjection.lookupRootScope)
        XCTAssertEqual(failClosedProjection.physicalRootPaths, Set([unloadablePhysicalRoot.standardizedFileURL.path]))
        XCTAssertFalse(failClosedProjection.isFullyMaterialized)
        XCTAssertEqual(
            failClosedProjection.lookupRootScope,
            .validatedSessionBoundWorkspace(canonicalRoots: [], physicalRoots: [])
        )
        XCTAssertEqual(scopeAvailability, .sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        XCTAssertEqual(
            catalogAccess,
            .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        )
        XCTAssertNotNil(visibleLookup)
        XCTAssertNil(scopedLookup)
        XCTAssertEqual(ownership.installedOwnerCount, 0)
        XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        XCTAssertEqual(ownership.rootClaimCount, 0)
    }

    func testMaterializerCommitsOwnershipWithoutCodemapDemandOrBuild() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionCommitLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionCommitPhysical")
        try write("struct CommitOnlyType {}\n", to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        let sessionID = UUID()
        let preparation = try await materializer.prepare(
            sessionID: sessionID,
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "commit")]
        )

        let projection = try await materializer.commit(preparation)
        let counts = await store.codemapPresentationOperationCountsForTesting()

        XCTAssertNotNil(projection)
        XCTAssertEqual(counts.artifactDemandRequests, 0)
        XCTAssertEqual(counts.presentationFreezeRequests, 0)
        await materializer.release(sessionID: sessionID)
        await store.unloadRoot(id: loadedLogicalRoot.id)
    }

    func testMaterializationStartsZeroCodemapTasks() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionMaterializeLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionMaterializePhysical")
        try write("struct MaterializedWithoutCodemapType {}\n", to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let sessionID = UUID()
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)

        let projection = await materializer.materialize(
            sessionID: sessionID,
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "materialize")]
        )
        await Task.yield()
        let counts = await store.codemapPresentationOperationCountsForTesting()

        XCTAssertNotNil(projection)
        XCTAssertEqual(counts.artifactDemandRequests, 0)
        XCTAssertEqual(counts.presentationFreezeRequests, 0)
        await materializer.release(sessionID: sessionID)
        await store.unloadRoot(id: loadedLogicalRoot.id)
    }

    func testMaterializedSessionWorktreeScopeReportsAvailable() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionAvailableLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionAvailablePhysical")
        try write("let origin = \"worktree\"\n", to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "available")]
        )
        let projection = try XCTUnwrap(materializedProjection)

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        let scopedRoots = await store.rootRefs(scope: projection.lookupRootScope)
        XCTAssertEqual(availability, .available)
        XCTAssertTrue(scopedRoots.contains {
            $0.standardizedFullPath == physicalRootURL.standardizedFileURL.path
        })
    }

    private static func binding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.fullPath,
            worktreeName: physicalRoot.fullPath.split(separator: "/").last.map(String.init),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
