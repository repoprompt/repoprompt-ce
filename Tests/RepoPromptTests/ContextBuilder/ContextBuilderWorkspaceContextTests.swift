import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class ContextBuilderWorkspaceContextTests: XCTestCase {
    func testResolveFreezesWorktreeProjectionProviderCWDAndNestedSnapshot() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderLogical")
        let worktreeRoot = try makeTemporaryDirectory(name: "ContextBuilderWorktree")
        defer {
            try? FileManager.default.removeItem(at: logicalRoot)
            try? FileManager.default.removeItem(at: worktreeRoot)
        }

        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)

        let sessionID = UUID()
        let parentRunID = UUID()
        let tabID = UUID()
        let workspaceID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        let selection = StoredSelection(
            selectedPaths: [logicalRoot.appendingPathComponent("Sources/App.swift").path],
            codemapAutoEnabled: false
        )
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: 41,
            workspaceID: workspaceID,
            promptText: "Inspect the branch implementation",
            selection: selection,
            selectedMetaPromptIDs: [UUID()],
            tabName: "Agent tab",
            runID: parentRunID,
            activeAgentSessionID: sessionID,
            worktreeBindings: [binding],
            explicitlyBound: true,
            readFileAutoSelectionGeneration: 7
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [logicalRoot.path],
            store: store
        )

        XCTAssertEqual(context.parentAgentSessionID, sessionID)
        XCTAssertEqual(context.parentAgentRunID, parentRunID)
        XCTAssertEqual(context.tabID, tabID)
        XCTAssertEqual(context.workspaceID, workspaceID)
        XCTAssertEqual(context.providerWorkspacePath, worktreeRoot.standardizedFileURL.path)
        XCTAssertEqual(
            context.lookupContext.translateInputPath(logicalRoot.appendingPathComponent("Sources/App.swift").path),
            worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path
        )

        let nestedRunID = UUID()
        let nested = context.nestedDiscoveryTabContext(runID: nestedRunID)
        XCTAssertEqual(nested.runID, nestedRunID)
        XCTAssertEqual(nested.activeAgentSessionID, sessionID)
        XCTAssertEqual(nested.worktreeBindings, [binding])
        XCTAssertEqual(nested.promptText, snapshot.promptText)
        XCTAssertEqual(nested.selection, snapshot.selection)
        XCTAssertEqual(nested.selectedMetaPromptIDs, snapshot.selectedMetaPromptIDs)
        XCTAssertTrue(nested.explicitlyBound)
        XCTAssertEqual(nested.readFileAutoSelectionGeneration, 7)
    }

    func testResolveWithoutBindingsFreezesCanonicalWorkspaceLookup() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderUnbound")
        let otherWorkspaceRoot = try makeTemporaryDirectory(name: "ContextBuilderOtherWorkspace")
        defer {
            try? FileManager.default.removeItem(at: logicalRoot)
            try? FileManager.default.removeItem(at: otherWorkspaceRoot)
        }
        try write("let value = true\n", to: logicalRoot.appendingPathComponent("App.swift"))
        try write("let other = true\n", to: otherWorkspaceRoot.appendingPathComponent("Other.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        _ = try await store.loadRoot(path: otherWorkspaceRoot.path)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 42,
            workspaceID: UUID(),
            promptText: "Question",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Unbound",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [logicalRoot.path],
            store: store
        )

        XCTAssertEqual(context.providerWorkspacePath, logicalRoot.standardizedFileURL.path)
        XCTAssertNil(context.lookupContext.bindingProjection)
        let frozenRoots = await store.rootRefs(scope: context.lookupContext.rootScope)
        XCTAssertEqual(Set(frozenRoots.map(\.standardizedFullPath)), Set([logicalRoot.standardizedFileURL.path]))
    }

    func testResolveFailsClosedWhenInheritedWorktreeIsUnavailable() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderMissingLogical")
        defer { try? FileManager.default.removeItem(at: logicalRoot) }
        let missingWorktree = logicalRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)")

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: missingWorktree)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 43,
            workspaceID: UUID(),
            promptText: "Question",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Missing worktree",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [binding],
            explicitlyBound: false
        )

        do {
            _ = try await ContextBuilderWorkspaceContext.resolve(
                from: snapshot,
                workspaceRepoPaths: [logicalRoot.path],
                store: store
            )
            XCTFail("Expected unavailable inherited worktree to fail closed")
        } catch let error as AgentWorktreeRuntimeWorkspaceError {
            XCTAssertEqual(error.binding, binding)
        }
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: "repo-id",
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: UUID().uuidString,
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/context-builder",
            head: "deadbeef",
            source: "test"
        )
    }
}
