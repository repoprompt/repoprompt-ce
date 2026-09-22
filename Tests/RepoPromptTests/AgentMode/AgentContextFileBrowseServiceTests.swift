@testable import RepoPromptApp
import XCTest

final class AgentContextFileBrowseServiceTests: XCTestCase {
    func testRootsTreeDescendantsExcludeGitDataAndProjectCodemapCapability() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseTree")
        try write("root b", to: rootURL.appendingPathComponent("b.txt"))
        try write("root a", to: rootURL.appendingPathComponent("a.swift"))
        try write("nested", to: rootURL.appendingPathComponent("zFolder/Nested.swift"))
        try write("nested", to: rootURL.appendingPathComponent("aFolder/Other.md"))
        let gitDataParent = try makeTestDirectory(name: "ContextBrowseGitData")
        let gitDataURL = gitDataParent.appendingPathComponent("_git_data", isDirectory: true)
        try write("hidden", to: gitDataURL.appendingPathComponent("Hidden.swift"))

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        _ = try await store.loadRoot(path: gitDataURL.path, kind: .workspaceGitData)
        let lookupContext = WorkspaceLookupContext(rootScope: .visibleWorkspacePlusGitData, bindingProjection: nil)
        let service = AgentContextFileBrowseService(store: store)

        let rootsResult = await service.roots(lookupContext: lookupContext)
        let roots = try availableRoots(rootsResult)
        let maybeHierarchy = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: lookupContext
        )
        let hierarchy = try XCTUnwrap(availableResult(maybeHierarchy))

        XCTAssertEqual(roots.roots.map(\.id), [root.id])
        XCTAssertEqual(hierarchy.folders.map(\.name), ["aFolder", "zFolder"])
        XCTAssertEqual(hierarchy.files.map(\.name), ["a.swift", "b.txt"])
        XCTAssertEqual(Set(hierarchy.descendantFiles.map(\.name)), ["a.swift", "b.txt", "Nested.swift", "Other.md"])
        XCTAssertEqual(hierarchy.descendantFiles.count, Set(hierarchy.descendantFiles.map(\.id)).count)
        XCTAssertTrue(hierarchy.files.allSatisfy { $0.rootGeneration == hierarchy.rootGeneration })
        XCTAssertTrue(hierarchy.descendantFiles.allSatisfy { $0.rootGeneration == hierarchy.rootGeneration })
        XCTAssertTrue(try XCTUnwrap(hierarchy.descendantFiles.first { $0.name == "a.swift" }).supportsCodemap)
        XCTAssertFalse(try XCTUnwrap(hierarchy.descendantFiles.first { $0.name == "b.txt" }).supportsCodemap)
        XCTAssertFalse(hierarchy.descendantFiles.contains { $0.standardizedFullPath.contains("_git_data") })
    }

    func testIndexedSearchIsUsedOnlyForAdmissibleVisibleAllRootSearch() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseIndexed")
        try write("target", to: rootURL.appendingPathComponent("Sources/Target.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let searchService = WorkspaceSearchService()
        await searchService.prepareIndex(from: snapshot)
        let service = AgentContextFileBrowseService(store: store, searchService: searchService)

        let indexed = try await availableResult(service.search(
            query: "Target",
            scope: .allRoots,
            lookupContext: .visibleWorkspace
        ))
        let rootScoped = try await availableResult(service.search(
            query: "Target",
            scope: .root(root.id),
            lookupContext: .visibleWorkspace
        ))
        let projectedContext = makeProjectedLookupContext(physicalRoot: root, logicalRootURL: rootURL)
        let projectedVisibleContext = WorkspaceLookupContext(
            rootScope: .visibleWorkspace,
            bindingProjection: projectedContext.bindingProjection
        )
        let projected = try await availableResult(service.search(
            query: "Target",
            scope: .allRoots,
            lookupContext: projectedVisibleContext
        ))

        XCTAssertEqual(indexed.source, .indexedVisibleWorkspace)
        XCTAssertEqual(rootScoped.source, .storeCatalog)
        XCTAssertEqual(projected.source, .storeCatalog)
        XCTAssertEqual(indexed.matches.map(\.file.name), ["Target.swift"])
        XCTAssertEqual(rootScoped.matches.map(\.file.name), ["Target.swift"])
        XCTAssertEqual(projected.matches.map(\.file.name), ["Target.swift"])
    }

    func testStaleIndexedSearchFallsBackToStoreForNewRoot() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseStaleIndexFallback")
        try write("fresh", to: rootURL.appendingPathComponent("Sources/FreshlyAddedBrowseUnique.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let staleIndexedSearch: AgentContextFileBrowseService.IndexedSearch = { query, _ in
            WorkspaceSearchQueryResult(
                query: query,
                indexedGeneration: 1,
                snapshotGeneration: 1,
                observedGeneration: 2,
                results: [],
                isIndexReady: true,
                isStale: true
            )
        }
        let service = AgentContextFileBrowseService(store: store, indexedSearch: staleIndexedSearch)

        let result = try await availableResult(service.search(
            query: "FreshlyAddedBrowseUnique",
            scope: .allRoots,
            lookupContext: .visibleWorkspace
        ))

        XCTAssertEqual(result.source, .storeCatalog)
        XCTAssertEqual(result.matches.map(\.file.name), ["FreshlyAddedBrowseUnique.swift"])
        XCTAssertEqual(result.matches.map(\.file.rootID), [root.id])
        XCTAssertEqual(result.groups.map(\.root.id), [root.id])
        XCTAssertEqual(result.groups.map(\.root.physicalPath), [root.standardizedFullPath])
        XCTAssertEqual(result.groups.flatMap(\.directories).map(\.directoryPath), ["Sources"])
    }

    func testSelectedRootSearchFiltersBeforeCandidateCap() async throws {
        let noisyRootURL = try makeTestDirectory(name: "ContextBrowseNoisy")
        let selectedRootURL = try makeTestDirectory(name: "ContextBrowseSelected")
        for index in 0 ..< 80 {
            try write("noise", to: noisyRootURL.appendingPathComponent(String(format: "Target%03d.swift", index)))
        }
        try write("selected", to: selectedRootURL.appendingPathComponent("TargetSelected.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: noisyRootURL.path)
        let selectedRoot = try await store.loadRoot(path: selectedRootURL.path)
        let service = AgentContextFileBrowseService(store: store)

        let result = try await availableResult(service.search(
            query: "Target",
            scope: .root(selectedRoot.id),
            lookupContext: .visibleWorkspace,
            limit: 1
        ))

        XCTAssertEqual(result.source, .storeCatalog)
        XCTAssertEqual(result.matches.map(\.file.name), ["TargetSelected.swift"])
        XCTAssertEqual(result.groups.map(\.root.id), [selectedRoot.id])
    }

    func testWorktreeProjectionUsesLogicalRootAndGroupsDuplicateRootNamesByPhysicalIdentity() async throws {
        let base = try makeTestDirectory(name: "ContextBrowseWorktree")
        let logicalA = base.appendingPathComponent("A/Shared", isDirectory: true)
        let logicalB = base.appendingPathComponent("B/Shared", isDirectory: true)
        let physicalA = base.appendingPathComponent("worktrees/A", isDirectory: true)
        let physicalB = base.appendingPathComponent("worktrees/B", isDirectory: true)
        try write("a", to: physicalA.appendingPathComponent("Sources/TargetA.swift"))
        try write("b", to: physicalB.appendingPathComponent("Sources/TargetB.swift"))
        let store = WorkspaceFileContextStore()
        let rootA = try await store.loadRoot(path: physicalA.path, kind: .sessionWorktree)
        let rootB = try await store.loadRoot(path: physicalB.path, kind: .sessionWorktree)
        let lookupContext = makeProjectedLookupContext(
            physicalRoots: [rootA, rootB],
            logicalRootURLs: [logicalA, logicalB]
        )
        let service = AgentContextFileBrowseService(store: store)

        let rootsResult = await service.roots(lookupContext: lookupContext)
        let roots = try availableRoots(rootsResult)
        let result = try await availableResult(service.search(
            query: "Target",
            scope: .allRoots,
            lookupContext: lookupContext
        ))

        XCTAssertEqual(roots.roots.map(\.displayName), ["Shared", "Shared"])
        XCTAssertEqual(Set(roots.roots.map(\.scopeLabel)), ["A/Shared", "B/Shared"])
        XCTAssertEqual(Set(result.groups.map(\.root.id)), [rootA.id, rootB.id])
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertTrue(result.groups.allSatisfy { $0.directories.map(\.directoryPath) == ["Sources"] })
        XCTAssertTrue(result.matches.allSatisfy { $0.file.projectedDisplayPath.contains("Shared/Sources/Target") })
        XCTAssertFalse(result.matches.contains { $0.file.projectedDisplayPath.contains("worktrees") })
        XCTAssertFalse(result.matches.contains { $0.file.standardizedFullPath == $0.file.projectedDisplayPath })
    }

    func testDuplicateRootTreeTitleUsesDisambiguatedScopeLabel() {
        let first = AgentContextFileBrowseRoot(
            id: UUID(),
            physicalPath: "/worktrees/first",
            displayName: "Shared",
            scopeLabel: "First/Shared"
        )
        let second = AgentContextFileBrowseRoot(
            id: UUID(),
            physicalPath: "/worktrees/second",
            displayName: "Shared",
            scopeLabel: "Second/Shared"
        )

        XCTAssertEqual(
            [first, second].map(agentContextFileBrowseTreeRootTitle),
            ["First/Shared", "Second/Shared"]
        )
    }

    func testRevalidationRejectsDeletedAndIdentityReplacedFilesWhilePreservingInputOrder() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseRevalidation")
        try write("one", to: rootURL.appendingPathComponent("One.swift"))
        try write("two", to: rootURL.appendingPathComponent("Two.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let service = AgentContextFileBrowseService(store: store)
        let maybeInitial = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: .visibleWorkspace
        )
        let initial = try XCTUnwrap(availableResult(maybeInitial))
        let one = try XCTUnwrap(initial.files.first { $0.name == "One.swift" })
        let two = try XCTUnwrap(initial.files.first { $0.name == "Two.swift" })

        try await store.deleteFile(rootID: root.id, relativePath: "One.swift")
        _ = try await store.createFile(rootID: root.id, relativePath: "One.swift", content: "replacement")
        let result = try await availableResult(
            service.revalidate(files: [two, one], lookupContext: .visibleWorkspace)
        )

        XCTAssertEqual(result.files.map(\.id), [two.id])
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertNotEqual(result.files.first?.rootGeneration, two.rootGeneration)
    }

    func testRootUnloadResolvesAsNormalAbsenceAcrossBrowseOperations() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseRootUnload")
        try write("one", to: rootURL.appendingPathComponent("One.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let service = AgentContextFileBrowseService(store: store)
        let maybeInitial = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: .visibleWorkspace
        )
        let initial = try XCTUnwrap(availableResult(maybeInitial))

        await store.unloadRoot(id: root.id)

        let hierarchy = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: .visibleWorkspace
        )
        let revalidated = try await availableResult(
            service.revalidate(files: initial.files, lookupContext: .visibleWorkspace)
        )
        let search = try await availableResult(service.search(
            query: "One",
            scope: .allRoots,
            lookupContext: .visibleWorkspace
        ))

        guard case let .missing(hierarchyGeneration) = hierarchy else {
            return XCTFail("Expected missing hierarchy with catalog generation")
        }
        XCTAssertNotEqual(hierarchyGeneration, initial.catalogGeneration)
        XCTAssertTrue(revalidated.files.isEmpty)
        XCTAssertEqual(revalidated.rejectedCount, initial.files.count)
        XCTAssertTrue(search.matches.isEmpty)
    }

    func testSessionScopeLossRemainsTypedAcrossTreeSearchAndRevalidation() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseSessionScopeLoss")
        try write("one", to: rootURL.appendingPathComponent("One.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path, kind: .sessionWorktree)
        let lookupContext = WorkspaceLookupContext(
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [root.standardizedFullPath]
            ),
            bindingProjection: nil
        )
        let service = AgentContextFileBrowseService(store: store)
        let initialResult = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: lookupContext
        )
        let initial = try XCTUnwrap(availableResult(initialResult))

        await store.unloadRoot(id: root.id)

        let hierarchy = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: lookupContext
        )
        let search = try await service.search(query: "One", scope: .allRoots, lookupContext: lookupContext)
        let revalidated = try await service.revalidate(files: initial.files, lookupContext: lookupContext)

        XCTAssertEqual(hierarchy, .sessionRootsUnavailable)
        XCTAssertEqual(search, .sessionRootsUnavailable)
        XCTAssertEqual(revalidated, .sessionRootsUnavailable)
    }

    func testNonMaterializedProjectionIsUnavailableAcrossBrowseOperations() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseIncompleteProjection")
        try write("one", to: rootURL.appendingPathComponent("One.swift"))
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path, kind: .sessionWorktree)
        let service = AgentContextFileBrowseService(store: store)
        let materializedContext = makeProjectedLookupContext(
            physicalRoot: root,
            logicalRootURL: rootURL
        )
        let initial = try await availableResult(service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: materializedContext
        ))
        let lookupContext = makeProjectedLookupContext(
            physicalRoots: [root],
            logicalRootURLs: [rootURL],
            lookupPhysicalRootPaths: []
        )

        let roots = await service.roots(lookupContext: lookupContext)
        let hierarchy = try await service.hierarchy(
            rootID: root.id,
            folderID: nil,
            lookupContext: lookupContext
        )
        let search = try await service.search(query: "One", scope: .allRoots, lookupContext: lookupContext)
        let revalidation = try await service.revalidate(files: initial.files, lookupContext: lookupContext)

        XCTAssertEqual(lookupContext.bindingProjection?.isFullyMaterialized, false)
        XCTAssertEqual(roots, .unavailable(missingPhysicalRootPaths: []))
        XCTAssertEqual(hierarchy, .sessionRootsUnavailable)
        XCTAssertEqual(search, .sessionRootsUnavailable)
        XCTAssertEqual(revalidation, .sessionRootsUnavailable)
    }

    func testSearchUsesBatchScorerOrderingAndDirectoryGrouping() async throws {
        let rootURL = try makeTestDirectory(name: "ContextBrowseScoring")
        try write("exact", to: rootURL.appendingPathComponent("Target.swift"))
        try write("nested", to: rootURL.appendingPathComponent("Sources/TargetHelper.swift"))
        try write("weak", to: rootURL.appendingPathComponent("Sources/UnrelatedTargetName.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootURL.path)
        let service = AgentContextFileBrowseService(store: store)

        let result = try await availableResult(service.search(
            query: "Target",
            scope: .allRoots,
            lookupContext: .visibleWorkspace
        ))
        let group = try XCTUnwrap(result.groups.first)

        XCTAssertEqual(result.matches.first?.file.name, "Target.swift")
        XCTAssertEqual(group.rootMatches.map(\.file.name), ["Target.swift"])
        XCTAssertEqual(group.directories.map(\.directoryPath), ["Sources"])
        XCTAssertEqual(group.matchCount, result.matches.count)
    }

    private func availableResult<Value>(
        _ result: AgentContextFileBrowseSessionScopedResult<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Value {
        guard case let .available(value) = result else {
            XCTFail("Expected available session roots", file: file, line: line)
            throw TestFailure.unavailableRoots
        }
        return value
    }

    private func availableRoots(
        _ result: AgentContextFileBrowseRootsResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentContextFileBrowseRootsSnapshot {
        guard case let .available(snapshot) = result else {
            XCTFail("Expected available roots", file: file, line: line)
            throw TestFailure.unavailableRoots
        }
        return snapshot
    }

    private func makeProjectedLookupContext(
        physicalRoot: WorkspaceRootRecord,
        logicalRootURL: URL
    ) -> WorkspaceLookupContext {
        makeProjectedLookupContext(physicalRoots: [physicalRoot], logicalRootURLs: [logicalRootURL])
    }

    private func makeProjectedLookupContext(
        physicalRoots: [WorkspaceRootRecord],
        logicalRootURLs: [URL],
        lookupPhysicalRootPaths: Set<String>? = nil
    ) -> WorkspaceLookupContext {
        precondition(physicalRoots.count == logicalRootURLs.count)
        let sessionID = UUID()
        let boundRoots = zip(physicalRoots, logicalRootURLs).enumerated().map { index, pair in
            let physical = WorkspaceRootRef(id: pair.0.id, name: pair.0.name, fullPath: pair.0.standardizedFullPath)
            let logical = WorkspaceRootRef(id: UUID(), name: pair.1.lastPathComponent, fullPath: pair.1.path)
            let binding = AgentSessionWorktreeBinding(
                id: "browse-bind-\(index)",
                repositoryID: "browse-repository-\(index)",
                repoKey: "browse",
                logicalRootPath: logical.standardizedFullPath,
                logicalRootName: logical.name,
                worktreeID: "browse-worktree-\(index)",
                worktreeRootPath: physical.standardizedFullPath,
                worktreeName: physical.name,
                branch: "feature/browse",
                head: "abcdef",
                visualLabel: "browse",
                visualColorHex: "#3366FF",
                boundAt: Date(timeIntervalSinceReferenceDate: 123),
                source: "test"
            )
            return WorkspaceRootBindingProjection.BoundRoot(
                logicalRoot: logical,
                physicalRoot: physical,
                binding: binding
            )
        }
        let projection = WorkspaceRootBindingProjection(
            sessionID: sessionID,
            boundRoots: boundRoots,
            visibleLogicalRoots: boundRoots.map(\.logicalRoot),
            lookupPhysicalRootPaths: lookupPhysicalRootPaths
        )
        return WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private enum TestFailure: Error {
        case unavailableRoots
    }
}
