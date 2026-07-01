import Foundation
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

                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            store: fixture.store,
            lookupContext: lookupContext
        )
        XCTAssertFalse(missingSnapshotBlock.contains("let branchOnly = true"), missingSnapshotBlock)
        XCTAssertFalse(missingSnapshotBlock.contains("<file_map>"), missingSnapshotBlock)

        let presentation = try await makePresentation(
            store: fixture.store,
            fileURL: worktreeCodemapURL,
            artifact: makeSyntaxArtifact(path: worktreeCodemapURL.path, symbolName: "branchOnlyCodemapSymbol")
        )

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: [fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path],

                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            store: fixture.store,
            lookupContext: lookupContext,
            codemapPresentation: presentation
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
        let artifact = makeSyntaxArtifact(
            path: worktreeURL.path,
            symbolName: "forkCapCodemapSentinel",
            imports: ["Foundation", "Combine"]
        )
        let selection = StoredSelection(
            codemapAutoEnabled: true
        )
        let rendered = artifact.renderedCodeMap(displayPath: "Sources/BranchOnly.swift")
        let renderedTokens = TokenCalculationService.estimateTokens(for: rendered)
        let presentation = try await makePresentation(
            store: fixture.store,
            fileURL: worktreeURL,
            artifact: artifact
        )

        let atCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens,
            store: fixture.store,
            lookupContext: lookupContext,
            codemapPresentation: presentation
        )
        XCTAssertTrue(atCap.contains("forkCapCodemapSentinel"), atCap)
        XCTAssertTrue(atCap.contains("  - Foundation"), atCap)
        XCTAssertFalse(atCap.contains(fixture.worktreeRoot.path), atCap)

        let summaryCalls = AgentProviderLockedCounter()
        let overCap = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: selection,
            tokenCap: renderedTokens - 1,
            store: fixture.store,
            lookupContext: lookupContext,
            codemapPresentation: presentation,
            overTokenCapSummaryProvider: { _, _, suppliedPresentation in
                summaryCalls.increment()
                XCTAssertEqual(suppliedPresentation.id, presentation.id)
                let retainedOriginal = suppliedPresentation.orderedEntries.contains {
                    $0.text.contains("forkCapCodemapSentinel")
                }
                return retainedOriginal ? "<selection_summary>frozen bundle</selection_summary>" : nil
            }
        )
        XCTAssertEqual(overCap, "<selection_summary>frozen bundle</selection_summary>")
        XCTAssertEqual(summaryCalls.value, 1)
    }

    @MainActor
    func testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "func makeTarget() -> Target { Target() }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        defer { repositories.cleanup() }

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }

        let tabID = UUID()
        let selection = StoredSelection(
            selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
            codemapAutoEnabled: true
        )
        let workspace = WorkspaceModel(
            name: "Agent over-cap borrowed presentation",
            repoPaths: [root.path],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Agent", selection: selection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentProviderContextBuilderTests"
        )
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        window.agentModeViewModel.test_setCurrentTabIDOverride(tabID)

        var countsBeforeSummary: WorkspaceFileContextStore.CodemapPresentationOperationCounts?
        #if DEBUG
            let refreshStartsBeforeHandoff = window.mcpServer.virtualTokenRefreshStartCountForTesting()
        #endif
        let block = await window.agentModeViewModel.buildCurrentTabHandoffFileContentsBlock(
            tokenCap: 0,
            overTokenCapSummaryWillBegin: {
                countsBeforeSummary = await window.workspaceFileContextStore
                    .codemapPresentationOperationCountsForTesting()
            }
        )
        let beforeSummary = try XCTUnwrap(countsBeforeSummary)
        let afterSummary = await window.workspaceFileContextStore.codemapPresentationOperationCountsForTesting()

        XCTAssertTrue(block.contains("<selection_summary>"), block)
        XCTAssertGreaterThan(beforeSummary.artifactDemandRequests, 0)
        XCTAssertEqual(afterSummary.artifactDemandRequests - beforeSummary.artifactDemandRequests, 0)
        XCTAssertEqual(afterSummary.presentationFreezeRequests - beforeSummary.presentationFreezeRequests, 0)
        #if DEBUG
            XCTAssertEqual(
                window.mcpServer.virtualTokenRefreshStartCountForTesting() - refreshStartsBeforeHandoff,
                0
            )
        #endif
    }

    private func makePresentation(
        store: WorkspaceFileContextStore,
        fileURL: URL,
        artifact: CodeMapSyntaxArtifact
    ) async throws -> WorkspaceCodemapOperationPresentation {
        let lookup = await store.lookupPath(fileURL.path, rootScope: .allLoaded)
        let file = try XCTUnwrap(lookup?.file)
        let rendered = artifact.renderedCodeMap(displayPath: file.standardizedRelativePath)
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let bundleID = WorkspaceCodemapFrozenPresentationBundleID()
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: file.standardizedRelativePath
        ))
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: [
                WorkspaceCodemapOperationRenderedEntry(
                    bundleID: bundleID,
                    fileID: file.id,
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: file.rootID,
                        rootLifetimeID: UUID()
                    ),
                    artifactKey: CodeMapArtifactKey(
                        rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 1, count: 32)),
                        rawByteCount: UInt64(rendered.utf8.count),
                        pipelineIdentity: pipeline
                    ),
                    logicalPath: logicalPath,
                    text: rendered,
                    tokenCount: TokenCalculationService.estimateTokens(for: rendered)
                )
            ],
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
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

    func testNonGitForkExportPreservesSelectedContentWithoutStartingCodemapRuntime() async throws {
        let root = try makeTemporaryRoot(name: "AgentProviderNonGit")
        try write(
            "struct NonGitSelected { let selectedContentSentinel = true }\n",
            to: root.appendingPathComponent("Sources/App.swift")
        )
        let runtimeAccessCount = AgentProviderLockedCounter()
        let store = WorkspaceFileContextStore(codemapRuntimeProvider: {
            runtimeAccessCount.increment()
            throw AgentProviderContextTestError.unexpectedRuntimeAccess
        })
        _ = try await store.loadRoot(path: root.path)

        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(
                selectedPaths: ["Sources/App.swift"],
                codemapAutoEnabled: true
            ),
            tokenCap: 10000,
            store: store,
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(block.contains("selectedContentSentinel"), block)
        XCTAssertFalse(block.contains("<file_map>"), block)
        XCTAssertEqual(runtimeAccessCount.value, 0)
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

    private func makeSyntaxArtifact(
        path: String,
        symbolName: String,
        imports: [String] = []
    ) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
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

private enum AgentProviderContextTestError: Error {
    case unexpectedRuntimeAccess
}

private final class AgentProviderLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
