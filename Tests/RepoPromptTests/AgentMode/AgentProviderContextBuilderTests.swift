@testable import RepoPrompt
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
            store: fixture.store,
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
            store: fixture.store,
            lookupContext: lookupContext
        )

        XCTAssertTrue(block.contains("File: Sources/App.swift"), block)
        XCTAssertTrue(block.contains("let origin = \"worktree\""), block)
        XCTAssertFalse(block.contains("let origin = \"base\""), block)
        XCTAssertFalse(block.contains(fixture.worktreeRoot.path), block)
    }

    func testForkFileContentsBlockIncludesCanonicalWorktreeCodemapExactlyOnce() async throws {
        let fixture = try await makeBoundFixture()
        let lookupContext = await makeLookupContext(fixture: fixture)
        let logicalCodemapURL = fixture.logicalRoot.appendingPathComponent("Sources/BranchOnly.swift")
        let worktreeCodemapURL = fixture.worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift")
        let missingSnapshotBlock = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: [],
                autoCodemapPaths: [logicalCodemapURL.path],
                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            store: fixture.store,
            lookupContext: lookupContext
        )
        XCTAssertFalse(missingSnapshotBlock.contains("let branchOnly = true"), missingSnapshotBlock)
        XCTAssertFalse(missingSnapshotBlock.contains("<file_map>"), missingSnapshotBlock)

        await fixture.store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: worktreeCodemapURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: worktreeCodemapURL.path, symbolName: "branchOnlyCodemapSymbol")
            )
        ])

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: [fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path],
                autoCodemapPaths: [logicalCodemapURL.path],
                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            store: fixture.store,
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
        await fixture.store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: worktreeURL.path,
                modificationDate: Date(),
                fileAPI: api
            )
        ])
        let selection = StoredSelection(
            autoCodemapPaths: [logicalURL.path],
            codemapAutoEnabled: true
        )
        let rendered = api.getFullAPIDescription(displayPath: "Sources/BranchOnly.swift")
        let renderedTokens = TokenCalculationService.estimateTokens(for: rendered)

        let atCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens,
            store: fixture.store,
            lookupContext: lookupContext
        )
        XCTAssertTrue(atCap.contains("forkCapCodemapSentinel"), atCap)
        XCTAssertTrue(atCap.contains("  - Foundation"), atCap)
        XCTAssertFalse(atCap.contains(fixture.worktreeRoot.path), atCap)

        let overCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens - 1,
            store: fixture.store,
            lookupContext: lookupContext,
            overTokenCapSummaryProvider: { _, _, frozenBundle in
                await fixture.store.applyObservedCodemapResults([
                    WorkspaceObservedCodemapResult(
                        fullPath: worktreeURL.path,
                        modificationDate: Date(),
                        fileAPI: nil
                    )
                ])
                let retainedOriginal = frozenBundle.orderedSnapshots.contains { snapshot in
                    snapshot.fileAPI?.apiDescription.contains("forkCapCodemapSentinel") == true
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
            store: fixture.store,
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
}
