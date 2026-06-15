import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPSelectionReplyFreshnessTests: XCTestCase {
    func testMutationReplyRereadsLiveTabSelectionAfterProviderStabilization() async throws {
        let root = try makeTemporaryRoot(name: "MutationReply")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let freshFile = root.appendingPathComponent("Fresh.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct Fresh {}\n", to: freshFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: [staleFile.path])
        let freshSelection = StoredSelection(selectedPaths: [freshFile.path])
        let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: staleSelection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        let providerStabilizedContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        let ingressBeforeReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = freshSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let reply = await window.mcpServer.buildSelectionMutationReply(
            from: staleSelection,
            includeBlocks: false,
            display: .full,
            virtualContext: providerStabilizedContext,
            lookupContext: .visibleWorkspace
        )

        let ingressAfterReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        XCTAssertEqual(reply.files?.map(\.path), [freshFile.path])
        XCTAssertEqual(ingressAfterReply.launchCount, ingressBeforeReply.launchCount)
    }

    func testCurrentReplyRereadsLiveTabSelectionAfterProviderStabilization() async throws {
        let root = try makeTemporaryRoot(name: "CurrentReply")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let freshFile = root.appendingPathComponent("Fresh.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct Fresh {}\n", to: freshFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: [staleFile.path])
        let freshSelection = StoredSelection(selectedPaths: [freshFile.path])
        let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: staleSelection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        let providerStabilizedContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        let resolvedContext = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: providerStabilizedContext,
            usesActiveTabCompatibility: false
        )
        let ingressBeforeReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = freshSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let reply = await window.mcpServer.buildCurrentSelectionReply(
            includeBlocks: false,
            display: .full,
            resolvedContext: resolvedContext,
            lookupContext: .visibleWorkspace
        )

        let ingressAfterReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        XCTAssertEqual(reply.files?.map(\.path), [freshFile.path])
        XCTAssertEqual(ingressAfterReply.launchCount, ingressBeforeReply.launchCount)
    }

    func testAlreadyAwaitedRepliesKeepProviderResolvedLookupContext() async throws {
        let workspaceRoot = try makeTemporaryRoot(name: "Workspace")
        let worktreeRoot = try makeTemporaryRoot(name: "Worktree")
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
        }
        try write("struct WorkspacePlaceholder {}\n", to: workspaceRoot.appendingPathComponent("Placeholder.swift"))
        let worktreeFile = worktreeRoot.appendingPathComponent("WorktreeOnly.swift")
        try write("struct WorktreeOnly {}\n", to: worktreeFile)

        let tabID = UUID()
        let logicalFile = workspaceRoot.appendingPathComponent(worktreeFile.lastPathComponent)
        let logicalSelection = StoredSelection(selectedPaths: [logicalFile.path])
        let (window, workspaceID) = await makeWindow(
            root: workspaceRoot,
            tabID: tabID,
            selection: logicalSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedWorkspaceRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: workspaceRoot.path
        )
        let loadedWorktreeRoot = try await window.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        let logicalRoot = WorkspaceRootRef(
            id: loadedWorkspaceRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorkspaceRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(
            id: loadedWorktreeRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorktreeRoot.standardizedFullPath
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: makeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)
                )
            ],
            visibleLogicalRoots: [logicalRoot]
        )
        let providerResolvedLookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let targetIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let targetWorkspace = try XCTUnwrap(
            window.workspaceManager.workspaces.first(where: { $0.id == workspaceID })
        )
        let unrelatedSelection = StoredSelection(selectedPaths: ["/tmp/unrelated-duplicate-tab.swift"])
        let unrelatedWorkspace = WorkspaceModel(
            name: "Unrelated Duplicate Tab",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Unrelated", selection: unrelatedSelection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [unrelatedWorkspace, targetWorkspace]
        var targetTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        targetTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(targetTab, inWorkspaceID: workspaceID))
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection, unrelatedSelection)
        XCTAssertEqual(window.workspaceManager.composeTab(for: targetIdentity)?.selection, logicalSelection)

        let context = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: logicalSelection
        )
        let resolvedContext = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: false
        )

        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        liveTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let currentReply = await window.mcpServer.buildCurrentSelectionReply(
            includeBlocks: false,
            display: .full,
            resolvedContext: resolvedContext,
            lookupContext: providerResolvedLookupContext
        )
        liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        liveTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let mutationReply = await window.mcpServer.buildSelectionMutationReply(
            from: logicalSelection,
            includeBlocks: false,
            display: .full,
            virtualContext: context,
            lookupContext: providerResolvedLookupContext
        )

        XCTAssertEqual(currentReply.files?.map(\.path), [logicalFile.path])
        XCTAssertEqual(mutationReply.files?.map(\.path), [logicalFile.path])
    }

    func testActiveCompatibilityLookupContextPreservesActiveSessionAuthority() async throws {
        let workspaceRoot = try makeTemporaryRoot(name: "CompatibilityWorkspace")
        let worktreeRoot = try makeTemporaryRoot(name: "CompatibilityWorktree")
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
        }
        try write("struct WorkspaceFile {}\n", to: workspaceRoot.appendingPathComponent("WorkspaceFile.swift"))
        try write("struct WorktreeFile {}\n", to: worktreeRoot.appendingPathComponent("WorktreeFile.swift"))

        let tabID = UUID()
        let sessionID = UUID()
        let (window, workspaceID) = await makeWindow(
            root: workspaceRoot,
            tabID: tabID,
            selection: StoredSelection()
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedWorkspaceRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: workspaceRoot.path
        )
        _ = try await window.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: nil,
            clientName: "selection-reply-compatibility-test",
            windowID: window.windowID
        )

        var bindingState = AgentSessionWorktreeBindingState.unavailable
        window.mcpServer.registerAgentWorktreeBindingsProvider { requestedSessionID, requestedTabID in
            guard requestedSessionID == sessionID, requestedTabID == tabID else { return .unavailable }
            return bindingState
        }

        let noSessionContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(noSessionContext, .visibleWorkspace)

        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        liveTab.activeAgentSessionID = sessionID
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))

        bindingState = .hydrated([])
        let emptyBindingContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(emptyBindingContext, .visibleWorkspace)

        let logicalRoot = WorkspaceRootRef(
            id: loadedWorkspaceRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorkspaceRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: loadedWorkspaceRoot.name,
            fullPath: worktreeRoot.path
        )
        bindingState = .hydrated([makeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)])
        let boundContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertNotNil(boundContext.bindingProjection)
        XCTAssertEqual(boundContext.rootScope, boundContext.bindingProjection?.lookupRootScope)
        XCTAssertEqual(
            boundContext.translateInputPath(workspaceRoot.appendingPathComponent("WorktreeFile.swift").path),
            worktreeRoot.appendingPathComponent("WorktreeFile.swift").path
        )

        bindingState = .unhydrated
        let unresolvedContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(
            unresolvedContext,
            WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []),
                bindingProjection: nil
            )
        )
    }

    private func makeWindow(
        root: URL,
        tabID: UUID,
        selection: StoredSelection
    ) async -> (window: WindowState, workspaceID: UUID) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = WorkspaceModel(
            name: "Selection Reply \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Agent", selection: selection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpSelectionReplyFreshnessTests"
        )
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        return (window, workspace.id)
    }

    private func makeContext(
        window: WindowState,
        workspaceID: UUID,
        tabID: UUID,
        selection: StoredSelection
    ) -> MCPServerViewModel.TabScopedContext {
        MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: "",
            selection: selection,
            selectedMetaPromptIDs: [],
            tabName: "Agent",
            runID: UUID(),
            explicitlyBound: true
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "selection-reply-binding",
            repositoryID: "selection-reply-repository",
            repoKey: "selection-reply-repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "selection-reply-worktree",
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/selection-reply",
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSelectionReplyFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
