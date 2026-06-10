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
        XCTAssertEqual(scope.kind, "session_bound_worktree")
        XCTAssertEqual(mapping.logicalRootName, "Project")
        XCTAssertEqual(mapping.logicalRootPath, "/repo/project")
        XCTAssertEqual(mapping.effectiveRootName, "project-agent")
        XCTAssertEqual(mapping.effectiveRootPath, "/tmp/worktrees/project-agent")
        XCTAssertEqual(mapping.worktreeID, "wt-1")
        XCTAssertEqual(mapping.branch, "feature/demo")
        XCTAssertEqual(mapping.label, "Demo Worktree")
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
            autoCodemapPaths: ["Sources/Dependency.swift"],
            slices: ["Sources/Sliced.swift": [LineRange(start: 3, end: 9)]],
            codemapAutoEnabled: false
        )

        let physicalSelection = projection.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, ["/tmp/worktrees/project-agent/Sources/App.swift"])
        XCTAssertEqual(physicalSelection.autoCodemapPaths, ["/tmp/worktrees/project-agent/Sources/Dependency.swift"])
        XCTAssertEqual(
            physicalSelection.slices["/tmp/worktrees/project-agent/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
        )

        let persistedSelection = projection.logicalizeSelection(physicalSelection)
        XCTAssertEqual(persistedSelection.selectedPaths, ["/repo/project/Sources/App.swift"])
        XCTAssertEqual(persistedSelection.autoCodemapPaths, ["/repo/project/Sources/Dependency.swift"])
        XCTAssertEqual(
            persistedSelection.slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
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

        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [binding]
        )
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let physicalSelection = lookupContext.physicalizeSelection(StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            codemapAutoEnabled: false
        ))
        let physicalPath = try XCTUnwrap(physicalSelection.selectedPaths.first)

        let boundLookup = await store.lookupPath(physicalPath, profile: .uiAssisted, rootScope: lookupContext.rootScope)
        let visibleLookup = await store.lookupPath("Sources/App.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let scopedRoots = await store.rootRefs(scope: lookupContext.rootScope)
        let availability = await store.rootScopeAvailability(lookupContext.rootScope)

        XCTAssertEqual(physicalPath, unloadablePhysicalRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path)
        XCTAssertNil(boundLookup)
        XCTAssertNotNil(visibleLookup)
        XCTAssertFalse(scopedRoots.contains { $0.standardizedFullPath == logicalRoot.standardizedFullPath })
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [unloadablePhysicalRoot.standardizedFileURL.path])
        )
    }

    func testMaterializerInitializesSessionWorktreeCodemapsIdempotently() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionCodemapLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionCodemapPhysical")
        try write(
            "struct WorktreeInitializedType {\n    func initializedMethod() {}\n}\n",
            to: physicalRootURL.appendingPathComponent("Sources/App.swift")
        )
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let binding = Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "codemap")

        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [binding]
        )
        let firstProjection = try XCTUnwrap(materializedProjection)
        let physicalRootID = try XCTUnwrap(firstProjection.physicalRootRefs.first?.id)

        let firstRedundantInitialization = await store.initializeCodemapsForSessionWorktreeRoots(rootIDs: [physicalRootID])
        XCTAssertTrue(firstRedundantInitialization.isEmpty)
        let snapshot = try await waitForCodemapSnapshot(
            store: store,
            rootID: physicalRootID,
            relativePath: "Sources/App.swift"
        )
        XCTAssertTrue(snapshot.fileAPI?.apiDescription.contains("WorktreeInitializedType") == true)

        _ = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [binding]
        )
        let secondRedundantInitialization = await store.initializeCodemapsForSessionWorktreeRoots(rootIDs: [physicalRootID])
        XCTAssertTrue(secondRedundantInitialization.isEmpty)
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

    private func waitForCodemapSnapshot(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        relativePath: String,
        timeout: Duration = .seconds(6)
    ) async throws -> WorkspaceCodemapSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = await store.codemapSnapshot(rootID: rootID, relativePath: relativePath) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for codemap snapshot")
        throw NSError(domain: "WorkspaceRootBindingProjectionTests", code: 1)
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
