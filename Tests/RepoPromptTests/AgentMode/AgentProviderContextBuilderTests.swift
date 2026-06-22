@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class AgentProviderContextBuilderTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testInitialFileTreeUsesBoundWorktreeAndLogicalPaths() async throws {
        let fixture = try await makeBoundFixture()
        let lookupContext = await makeLookupContext(fixture: fixture)

        let fileTree = await AgentProviderContextBuilder.initialFileTree(
            selection: StoredSelection(),
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: lookupContext
        )

        XCTAssertTrue(fileTree.contains("BranchOnly.swift"), fileTree)
        XCTAssertFalse(fileTree.contains("BaseOnly.swift"), fileTree)
        XCTAssertFalse(fileTree.contains(fixture.worktreeRoot.path), fileTree)
    }

    func testForkFileContentsBlockReadsWorktreeContentAndDisplaysLogicalPath() async throws {
        let fixture = try await makeBoundFixture()
        let lookupContext = await makeLookupContext(fixture: fixture)

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            tokenCap: 10000,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: lookupContext
        )

        XCTAssertTrue(block.contains("File: Sources/App.swift"), block)
        XCTAssertTrue(block.contains("let origin = \"worktree\""), block)
        XCTAssertFalse(block.contains("let origin = \"base\""), block)
        XCTAssertFalse(block.contains(fixture.worktreeRoot.path), block)
    }

    func testForkFileContentsBlockIncludesCanonicalWorktreeCodemapExactlyOnce() async throws {
        let missingFixture = try await makeBoundFixture()
        let missingLookupContext = await makeLookupContext(fixture: missingFixture)
        let missingLogicalCodemapURL = missingFixture.logicalRoot
            .appendingPathComponent("Sources/BranchOnly.rpfixture")
        let missingSnapshotBlock = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: [],
                autoCodemapPaths: [missingLogicalCodemapURL.path],
                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: missingFixture.store),
            lookupContext: missingLookupContext
        )
        XCTAssertFalse(missingSnapshotBlock.contains("let branchOnly = true"), missingSnapshotBlock)
        XCTAssertFalse(missingSnapshotBlock.contains("<file_map>"), missingSnapshotBlock)

        let fixture = try await makeBoundFixture()
        let lookupContext = await makeLookupContext(fixture: fixture)
        let logicalCodemapURL = fixture.logicalRoot.appendingPathComponent("Sources/BranchOnly.swift")
        let worktreeCodemapURL = fixture.worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift")
        await awaitCodemapSnapshot(
            fixture.store,
            scope: lookupContext.rootScope,
            relativePath: "Sources/BranchOnly.swift"
        )
        await quiesceCodemapActivity(fixture.store, scope: lookupContext.rootScope)
        await fixture.store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: worktreeCodemapURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: worktreeCodemapURL.path, symbolName: "branchOnlyCodemapSymbol")
            )
        ])
        await awaitStableCatalog(fixture.store, scope: lookupContext.rootScope)

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: [fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path],
                autoCodemapPaths: [logicalCodemapURL.path],
                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: lookupContext
        )
        XCTAssertTrue(block.contains("<file_map>"), block)
        XCTAssertEqual(block.components(separatedBy: "branchOnlyCodemapSymbol").count - 1, 1, block)
        XCTAssertTrue(block.contains("File: Sources/BranchOnly.swift"), block)
        XCTAssertTrue(block.contains("<file_contents>"), block)
        XCTAssertTrue(block.contains("let origin = \"worktree\""), block)
        XCTAssertFalse(block.contains("let branchOnly = true"), block)
        XCTAssertFalse(block.contains(fixture.worktreeRoot.path), block)
    }

    func testForkCodemapCapIncludesRenderedHeaderImportsAndFreezesFallbackBundle() async throws {
        let fixture = try await makeBoundFixture()
        let lookupContext = await makeLookupContext(fixture: fixture)
        let logicalURL = fixture.logicalRoot.appendingPathComponent("Sources/BranchOnly.swift")
        let worktreeURL = fixture.worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift")
        let api = makeFileAPI(
            path: worktreeURL.path,
            symbolName: "forkCapCodemapSentinel",
            imports: ["Foundation", "Combine"]
        )
        await awaitCodemapSnapshot(
            fixture.store,
            scope: lookupContext.rootScope,
            relativePath: "Sources/BranchOnly.swift"
        )
        await quiesceCodemapActivity(fixture.store, scope: lookupContext.rootScope)
        await fixture.store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: worktreeURL.path,
                modificationDate: Date(),
                fileAPI: api
            )
        ])
        await awaitStableCatalog(fixture.store, scope: lookupContext.rootScope)
        let selection = StoredSelection(
            autoCodemapPaths: [logicalURL.path],
            codemapAutoEnabled: true
        )
        let rendered = api.getFullAPIDescription(displayPath: "Sources/BranchOnly.swift")
        let renderedTokens = TokenCalculationService.estimateTokens(for: rendered)

        let atCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: lookupContext
        )
        XCTAssertTrue(atCap.contains("forkCapCodemapSentinel"), atCap)
        XCTAssertTrue(atCap.contains("  - Foundation"), atCap)
        XCTAssertFalse(atCap.contains(fixture.worktreeRoot.path), atCap)

        let overCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens - 1,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: lookupContext,
            overTokenCapSummaryProvider: { snapshot in
                await fixture.store.applyObservedCodemapResults([
                    WorkspaceObservedCodemapResult(
                        fullPath: worktreeURL.path,
                        modificationDate: Date(),
                        fileAPI: nil
                    )
                ])
                let retainedOriginal = snapshot.rendered.codemapBlocks.contains {
                    $0.contains("forkCapCodemapSentinel")
                }
                return retainedOriginal ? "<selection_summary>frozen bundle</selection_summary>" : nil
            }
        )
        XCTAssertEqual(overCap, "<selection_summary>frozen bundle</selection_summary>")
    }

    func testNonWorktreeForkFileContentsPreservesVisibleWorkspaceBehavior() async throws {
        let fixture = try await makeBoundFixture()
        _ = await makeLookupContext(fixture: fixture) // Keep the hidden session worktree loaded.

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            tokenCap: 10000,
            factualProvider: AgentProviderBuilderTestFactualProvider(store: fixture.store),
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(block.contains("let origin = \"base\""), block)
        XCTAssertFalse(block.contains("let origin = \"worktree\""), block)
    }

    private func makeBoundFixture() async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        sessionID: UUID,
        binding: AgentSessionWorktreeBinding
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "AgentProviderContextLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AgentProviderContextWorktree")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let baseOnly = true\n", to: logicalRoot.appendingPathComponent("Sources/BaseOnly.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))
        try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.rpfixture"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        return (logicalRoot, worktreeRoot, store, sessionID, binding)
    }

    private func makeLookupContext(
        fixture: (
            logicalRoot: URL,
            worktreeRoot: URL,
            store: WorkspaceFileContextStore,
            sessionID: UUID,
            binding: AgentSessionWorktreeBinding
        )
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: fixture.sessionID,
                worktreeBindings: [fixture.binding]
            ),
            store: fixture.store
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        imports: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: imports,
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func awaitStableCatalog(
        _ store: WorkspaceFileContextStore,
        scope: WorkspaceLookupRootScope
    ) async {
        var previous: UInt64?
        var stableSamples = 0
        for _ in 0 ..< 200 {
            _ = await store.awaitAppliedIngress(rootScope: scope)
            let current = await store.catalogGeneration(rootScope: scope)
            stableSamples = current == previous ? stableSamples + 1 : 0
            if stableSamples >= 4 { return }
            previous = current
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func quiesceCodemapActivity(
        _ store: WorkspaceFileContextStore,
        scope: WorkspaceLookupRootScope
    ) async {
        for root in await store.rootRefs(scope: scope) {
            if let service = await store.fileSystemServiceForTesting(rootID: root.id) {
                await service.stopWatchingForChanges()
            }
        }
        await store.cancelAllCodemapScans()
    }

    private func awaitCodemapSnapshot(
        _ store: WorkspaceFileContextStore,
        scope: WorkspaceLookupRootScope,
        relativePath: String
    ) async {
        for _ in 0 ..< 200 {
            let roots = await store.rootRefs(scope: scope)
            for root in roots {
                if await store.codemapSnapshot(rootID: root.id, relativePath: relativePath) != nil {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for worktree codemap snapshot at \(relativePath)")
    }
}

private struct AgentProviderBuilderTestFactualProvider: PromptFactualContextProviding {
    let store: WorkspaceFileContextStore

    func capture(
        _ request: PromptFactualCaptureRequest,
        admission _: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome {
        var latest = await PromptFactualContextCaptureService.capture(request: request, store: store)
        for _ in 0 ..< 20 {
            guard case .unavailable(.staleGeneration) = latest else { return latest }
            try? await Task.sleep(for: .milliseconds(25))
            latest = await PromptFactualContextCaptureService.capture(request: request, store: store)
        }
        return latest
    }
}
