@testable import RepoPrompt
import XCTest

final class AgentProviderContextBuilderTests: XCTestCase {
    private enum AccountingTestError: Error {
        case failed
    }

    private actor AccountingCancellationGate {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

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

    func testForkFileContentsBlockFailsClosedWhenAccountingThrows() async {
        let block = await AgentProviderContextBuilder.forkFileContentsBlock(
            selection: StoredSelection(selectedPaths: ["Sources/Oversized.swift"], codemapAutoEnabled: false),
            tokenCap: 1,
            store: WorkspaceFileContextStore(),
            lookupContext: .visibleWorkspace,
            accountingOperation: { _, _ in throw AccountingTestError.failed },
            overTokenCapSummaryProvider: { _, _ in "unsafe fallback summary" }
        )

        XCTAssertEqual(block, "")
    }

    func testForkFileContentsBlockFailsClosedWhenAccountingIsCancelled() async {
        let gate = AccountingCancellationGate()
        let task = Task {
            await AgentProviderContextBuilder.forkFileContentsBlock(
                selection: StoredSelection(selectedPaths: ["Sources/Oversized.swift"], codemapAutoEnabled: false),
                tokenCap: 1,
                store: WorkspaceFileContextStore(),
                lookupContext: .visibleWorkspace,
                accountingOperation: { _, _ in
                    await gate.markStarted()
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw AccountingTestError.failed
                },
                overTokenCapSummaryProvider: { _, _ in "unsafe fallback summary" }
            )
        }
        await gate.waitUntilStarted()

        task.cancel()
        let block = await task.value

        XCTAssertEqual(block, "")
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
}
