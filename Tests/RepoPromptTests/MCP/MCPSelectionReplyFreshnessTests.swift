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

    #if DEBUG
        func testActiveMCPTokenRepliesCompleteWhileBackgroundRecountIsBlockedAndCoalesce() async throws {
            let root = try makeTemporaryRoot(name: "ActiveTokenCache")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Cached.swift")
            try write("struct ActiveCachedTokenType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            let tokenCounter = window.promptManager.tokenCountingViewModel
            await tokenCounter.forceImmediateRecount()
            let recountGate = TokenAccountingGate()
            tokenCounter.setBeforeTokenCalculationForTesting {
                await recountGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await recountGate.release()
                    tokenCounter.setBeforeTokenCalculationForTesting(nil)
                }
            }

            let baselineStarts = tokenCounter.tokenCalculationStartCountForTesting()
            tokenCounter.markDirty(.selection)
            await recountGate.waitUntilStarted()

            let context = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection
            )
            let activeResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: context,
                usesActiveTabCompatibility: true
            )
            let repliesCompleted = expectation(description: "active token replies complete while recount is blocked")
            var selectionReply: ToolResultDTOs.SelectionReply?
            var workspaceReply: ToolResultDTOs.PromptContextDTO?
            var replyError: Error?
            Task { @MainActor in
                selectionReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: activeResolution,
                    lookupContext: .visibleWorkspace
                )
                do {
                    workspaceReply = try await window.mcpServer.buildTabWorkspaceContext(
                        context: context,
                        include: ["selection", "tokens"],
                        display: .relative,
                        activeTabCompatibility: true
                    )
                } catch {
                    replyError = error
                }
                repliesCompleted.fulfill()
            }
            await fulfillment(of: [repliesCompleted], timeout: 1)
            if let replyError { throw replyError }
            let resolvedSelectionReply = try XCTUnwrap(selectionReply)
            let resolvedWorkspaceReply = try XCTUnwrap(workspaceReply)

            XCTAssertEqual(resolvedSelectionReply.tokenAccounting?.source, "active_tab_published")
            XCTAssertTrue(resolvedSelectionReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.source, "active_tab_published")
            XCTAssertTrue(resolvedWorkspaceReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(tokenCounter.tokenCalculationStartCountForTesting(), baselineStarts + 1)

            await recountGate.release()
            tokenCounter.setBeforeTokenCalculationForTesting(nil)
        }

        func testBoundMCPTokenRepliesCompleteWhileContentRefreshIsBlockedAndCoalesce() async throws {
            let root = try makeTemporaryRoot(name: "BoundTokenCache")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Bound.swift")
            try write("struct BoundCachedTokenType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.promptManager.tokenCountingViewModel.forceImmediateRecount()
            let refreshGate = TokenAccountingGate()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting {
                await refreshGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await refreshGate.release()
                    window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
                }
            }

            let context = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection
            )
            let boundResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: context,
                usesActiveTabCompatibility: false
            )
            let baselineStarts = window.mcpServer.virtualTokenRefreshStartCountForTesting()
            let firstCompleted = expectation(description: "first bound token reply completes before refresh")
            var firstReply: ToolResultDTOs.SelectionReply?
            Task { @MainActor in
                firstReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: boundResolution,
                    lookupContext: .visibleWorkspace
                )
                firstCompleted.fulfill()
            }
            await refreshGate.waitUntilStarted()
            await fulfillment(of: [firstCompleted], timeout: 1)

            let remainingCompleted = expectation(description: "coalesced bound token replies complete while refresh is blocked")
            var secondReply: ToolResultDTOs.SelectionReply?
            var workspaceReply: ToolResultDTOs.PromptContextDTO?
            var replyError: Error?
            Task { @MainActor in
                secondReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: boundResolution,
                    lookupContext: .visibleWorkspace
                )
                do {
                    workspaceReply = try await window.mcpServer.buildTabWorkspaceContext(
                        context: context,
                        include: ["selection", "tokens"],
                        display: .relative,
                        activeTabCompatibility: false
                    )
                } catch {
                    replyError = error
                }
                remainingCompleted.fulfill()
            }
            await fulfillment(of: [remainingCompleted], timeout: 1)
            if let replyError { throw replyError }
            let resolvedFirstReply = try XCTUnwrap(firstReply)
            let resolvedSecondReply = try XCTUnwrap(secondReply)
            let resolvedWorkspaceReply = try XCTUnwrap(workspaceReply)

            XCTAssertEqual(resolvedFirstReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedFirstReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedFirstReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(resolvedSecondReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedSecondReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedSecondReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedWorkspaceReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), baselineStarts + 1)
            let refreshStartCount = await refreshGate.startCount()
            // Identical bound selection and workspace token requests share one signature,
            // so all cached replies coalesce onto the same background refresh.
            XCTAssertEqual(refreshStartCount, 1)

            await refreshGate.release()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
        }

        func testBoundMCPTokenRefreshesForDistinctSignaturesDoNotCancelEachOther() async throws {
            let root = try makeTemporaryRoot(name: "BoundTokenSignatures")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Bound.swift")
            try write("struct BoundDistinctSignatureType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.promptManager.tokenCountingViewModel.forceImmediateRecount()
            let refreshGate = TokenAccountingGate()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting {
                await refreshGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await refreshGate.release()
                    window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
                }
            }

            let firstContext = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection,
                promptText: "First signature"
            )
            let secondContext = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection,
                promptText: "Second signature"
            )
            let firstResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: firstContext,
                usesActiveTabCompatibility: false
            )
            let secondResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: secondContext,
                usesActiveTabCompatibility: false
            )
            let baselineStarts = window.mcpServer.virtualTokenRefreshStartCountForTesting()

            let firstReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: firstResolution,
                lookupContext: .visibleWorkspace
            )
            await refreshGate.waitUntilStarted(count: 1)
            let secondReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: secondResolution,
                lookupContext: .visibleWorkspace
            )
            await refreshGate.waitUntilStarted(count: 2)

            XCTAssertEqual(firstReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(secondReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), baselineStarts + 2)
            let refreshStartCount = await refreshGate.startCount()
            XCTAssertEqual(refreshStartCount, 2)

            await refreshGate.release()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
            for _ in 0 ..< 100 where window.mcpServer.virtualTokenRefreshTaskCountForTesting() > 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshTaskCountForTesting(), 0)

            let firstCachedReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: firstResolution,
                lookupContext: .visibleWorkspace
            )
            let secondCachedReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: secondResolution,
                lookupContext: .visibleWorkspace
            )
            XCTAssertEqual(firstCachedReply.tokenAccounting?.source, "bound_tab_cache")
            XCTAssertEqual(secondCachedReply.tokenAccounting?.source, "bound_tab_cache")
        }
    #endif

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
        selection: StoredSelection,
        promptText: String = ""
    ) -> MCPServerViewModel.TabScopedContext {
        MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: promptText,
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

#if DEBUG
    private actor TokenAccountingGate {
        private var startedCount = 0
        private var released = false
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            let readyWaiters = startWaiters.filter { $0.count <= startedCount }
            startWaiters.removeAll { $0.count <= startedCount }
            readyWaiters.forEach { $0.continuation.resume() }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted(count: Int = 1) async {
            guard startedCount < count else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append((count, continuation))
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func startCount() -> Int {
            startedCount
        }
    }
#endif
