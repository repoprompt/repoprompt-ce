import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class WorkingDirsBindRootProjectionTests: XCTestCase {
    func testWorkingDirsLoadedRootValidationAcceptsDifferentlyCasedEquivalentPath() {
        let loadedRoot = "/private/tmp/RepoPrompt/WorkingRoot"
        let differentlyCasedRequest = "/PRIVATE/TMP/repoprompt/workingroot"

        XCTAssertEqual(
            WindowRoutingService.missingWorkingDirsRootProjectionPaths(
                requestedRoots: [differentlyCasedRequest],
                loadedRoots: [loadedRoot]
            ),
            []
        )
    }

    @MainActor
    func testWorkingDirsBindHydratesAgentProjectionBeforeBinding() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
        }

        let logicalRootURL = try makeTemporaryDirectory(named: "working-dirs-hydration-logical")
        let physicalRootURL = try makeTemporaryDirectory(named: "working-dirs-hydration-physical")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: logicalRootURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: physicalRootURL.deletingLastPathComponent())
        }

        let previousTabID = UUID()
        let agentTabID = UUID()
        let agentSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Working Dirs Hydration",
            repoPaths: [logicalRootURL.path],
            customStoragePath: logicalRootURL.appendingPathComponent("workspace.json"),
            composeTabs: [
                ComposeTabState(id: previousTabID, name: "Previous"),
                ComposeTabState(
                    id: agentTabID,
                    name: "Hydrating Agent",
                    activeAgentSessionID: agentSessionID
                )
            ],
            activeComposeTabID: agentTabID
        )
        try await install(workspace: workspace, in: window, reason: "workingDirsHydrationTest")
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let physicalRoot = try await window.workspaceFileContextStore.loadRoot(
            path: physicalRootURL.path,
            kind: .sessionWorktree
        )
        let binding = makeWorktreeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)

        var bindingState = AgentSessionWorktreeBindingState.unhydrated
        var hydrationCount = 0
        window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
            guard sessionID == agentSessionID, tabID == agentTabID else { return .unavailable }
            return bindingState
        }
        window.mcpServer.registerAgentWorktreeBindingsResolver { sessionID, tabID in
            XCTAssertEqual(sessionID, agentSessionID)
            XCTAssertEqual(tabID, agentTabID)
            hydrationCount += 1
            bindingState = .hydrated([binding])
            return bindingState
        }

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "working-dirs-hydration-test",
            tabID: previousTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let (service, bindContext) = try await bindContextTool(for: window)
        defer { withExtendedLifetime(service) {} }

        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await bindContext([
                "op": .string("bind"),
                "working_dirs": .string(logicalRootURL.path),
                "create_if_missing": .bool(false)
            ])
        }

        XCTAssertEqual(hydrationCount, 1)
        XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.tabID, agentTabID)
        let lookupContext = await window.mcpServer.resolveFileToolLookupContext(from: .init(
            connectionID: connectionID,
            clientName: "working-dirs-hydration-test",
            windowID: window.windowID,
            runPurpose: .unknown
        ))
        XCTAssertEqual(
            lookupContext.translateInputPath(logicalRootURL.appendingPathComponent("Sources/New.swift").path),
            physicalRootURL.appendingPathComponent("Sources/New.swift").path
        )
    }

    @MainActor
    func testWorkingDirsBindPreservesPreviousBindingWhenActiveTabChangesDuringPreflight() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
        }

        let rootURL = try makeTemporaryDirectory(named: "working-dirs-stale-target")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }

        let previousTabID = UUID()
        let prospectiveTabID = UUID()
        let replacementTabID = UUID()
        let agentSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Working Dirs Stale Target",
            repoPaths: [rootURL.path],
            customStoragePath: rootURL.appendingPathComponent("workspace.json"),
            composeTabs: [
                ComposeTabState(id: previousTabID, name: "Previous"),
                ComposeTabState(
                    id: prospectiveTabID,
                    name: "Prospective Agent",
                    activeAgentSessionID: agentSessionID
                ),
                ComposeTabState(id: replacementTabID, name: "Replacement")
            ],
            activeComposeTabID: prospectiveTabID
        )
        try await install(workspace: workspace, in: window, reason: "workingDirsStaleTargetTest")
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: rootURL.path
        )

        var bindingState = AgentSessionWorktreeBindingState.unhydrated
        let hydrationGate = WorkingDirsHydrationGate()
        window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
            guard sessionID == agentSessionID, tabID == prospectiveTabID else { return .unavailable }
            return bindingState
        }
        window.mcpServer.registerAgentWorktreeBindingsResolver { sessionID, tabID in
            XCTAssertEqual(sessionID, agentSessionID)
            XCTAssertEqual(tabID, prospectiveTabID)
            await hydrationGate.markStartedAndWaitForRelease()
            bindingState = .hydrated([])
            return bindingState
        }

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "working-dirs-stale-target-test",
            tabID: previousTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let (service, bindContext) = try await bindContextTool(for: window)
        defer { withExtendedLifetime(service) {} }
        let bindTask = Task { @MainActor in
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await bindContext([
                    "op": .string("bind"),
                    "working_dirs": .string(rootURL.path),
                    "create_if_missing": .bool(false)
                ])
            }
        }
        addTeardownBlock {
            bindTask.cancel()
            await hydrationGate.release()
            _ = try? await bindTask.value
        }

        await hydrationGate.waitUntilStarted()
        let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = replacementTabID
        await hydrationGate.release()

        do {
            _ = try await bindTask.value
            XCTFail("Expected the stale working_dirs target to be rejected")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("changed while its root projection was being resolved"), message)
            XCTAssertTrue(message.contains("existing MCP binding was not changed"), message)
        }
        XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.tabID, previousTabID)
    }

    @MainActor
    func testWorkingDirsBindPreservesPreviousBindingWhenActiveTabChangesAfterRootValidation() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
        }

        let rootURL = try makeTemporaryDirectory(named: "working-dirs-commit-target")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }

        let previousTabID = UUID()
        let prospectiveTabID = UUID()
        let replacementTabID = UUID()
        let workspace = WorkspaceModel(
            name: "Working Dirs Commit Target",
            repoPaths: [rootURL.path],
            customStoragePath: rootURL.appendingPathComponent("workspace.json"),
            composeTabs: [
                ComposeTabState(id: previousTabID, name: "Previous"),
                ComposeTabState(id: prospectiveTabID, name: "Prospective"),
                ComposeTabState(id: replacementTabID, name: "Replacement")
            ],
            activeComposeTabID: prospectiveTabID
        )
        try await install(workspace: workspace, in: window, reason: "workingDirsCommitTargetTest")
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: rootURL.path
        )

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "working-dirs-commit-target-test",
            tabID: previousTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting {
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
            guard let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
                XCTFail("Workspace disappeared before the commit-time target change")
                return
            }
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = replacementTabID
        }
        addTeardownBlock { @MainActor in
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
        }

        let (service, bindContext) = try await bindContextTool(for: window)
        defer { withExtendedLifetime(service) {} }
        do {
            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await bindContext([
                    "op": .string("bind"),
                    "working_dirs": .string(rootURL.path),
                    "create_if_missing": .bool(false)
                ])
            }
            XCTFail("Expected the commit-time target change to reject the stale working_dirs bind")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("changed while its root projection was being resolved"), message)
            XCTAssertTrue(message.contains("existing MCP binding was not changed"), message)
        }
        XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.tabID, previousTabID)
    }

    @MainActor
    func testWorkingDirsBindPreservesPreviousBindingWhenSessionRootLifetimeChangesAfterPreflight() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
        }

        let logicalRootURL = try makeTemporaryDirectory(named: "working-dirs-lifetime-logical")
        let physicalRootURL = try makeTemporaryDirectory(named: "working-dirs-lifetime-physical")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: logicalRootURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: physicalRootURL.deletingLastPathComponent())
        }

        let previousTabID = UUID()
        let agentTabID = UUID()
        let agentSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Working Dirs Lifetime Fence",
            repoPaths: [logicalRootURL.path],
            customStoragePath: logicalRootURL.appendingPathComponent("workspace.json"),
            composeTabs: [
                ComposeTabState(id: previousTabID, name: "Previous"),
                ComposeTabState(
                    id: agentTabID,
                    name: "Prospective Agent",
                    activeAgentSessionID: agentSessionID
                )
            ],
            activeComposeTabID: agentTabID
        )
        try await install(workspace: workspace, in: window, reason: "workingDirsLifetimeFenceTest")
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let physicalRoot = try await window.workspaceFileContextStore.loadRoot(
            path: physicalRootURL.path,
            kind: .sessionWorktree
        )
        let binding = makeWorktreeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)
        window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
            sessionID == agentSessionID && tabID == agentTabID ? .hydrated([binding]) : .unavailable
        }

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "working-dirs-lifetime-fence-test",
            tabID: previousTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting {
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
            await window.workspaceFileContextStore.unloadRoot(id: physicalRoot.id)
            do {
                let replacementRoot = try await window.workspaceFileContextStore.loadRoot(
                    path: physicalRootURL.path,
                    kind: .sessionWorktree
                )
                XCTAssertNotEqual(replacementRoot.id, physicalRoot.id)
            } catch {
                XCTFail("Failed to reload the session root during the deterministic race: \(error)")
            }
        }
        addTeardownBlock { @MainActor in
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
        }

        let (service, bindContext) = try await bindContextTool(for: window)
        defer { withExtendedLifetime(service) {} }
        do {
            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await bindContext([
                    "op": .string("bind"),
                    "working_dirs": .string(logicalRootURL.path),
                    "create_if_missing": .bool(false)
                ])
            }
            XCTFail("Expected session-root lifetime churn to reject the stale working_dirs bind")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("changed while its root projection was being resolved"), message)
            XCTAssertTrue(message.contains("existing MCP binding was not changed"), message)
        }
        XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.tabID, previousTabID)
    }

    @MainActor
    func testWorkingDirsBindRejectsRootlessAgentTabWithoutReplacingBinding() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-dirs-root-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let previousTabID = UUID()
        let rootlessTabID = UUID()
        let agentSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Working Dirs Root Projection",
            repoPaths: [root.path],
            customStoragePath: root.appendingPathComponent("workspace.json"),
            composeTabs: [
                ComposeTabState(id: previousTabID, name: "Previous"),
                ComposeTabState(
                    id: rootlessTabID,
                    name: "Rootless Agent",
                    activeAgentSessionID: agentSessionID
                )
            ],
            activeComposeTabID: rootlessTabID
        )
        window.workspaceManager.workspaces = [workspace]
        let switchResult = await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "workingDirsRootProjectionTest"
        )
        XCTAssertTrue(switchResult.didSwitch)
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        let visibleRoots = await window.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
        XCTAssertEqual(visibleRoots.map(\.standardizedFullPath), [StandardizedPath.absolute(root.path)])

        window.mcpServer.registerAgentWorktreeBindingsProvider { sessionID, tabID in
            sessionID == agentSessionID && tabID == rootlessTabID ? .unavailable : .notApplicable
        }
        let prospectiveLookupContext = try await window.mcpServer.resolveFileToolLookupContext(
            tabID: rootlessTabID,
            workspaceID: workspace.id
        )
        XCTAssertEqual(prospectiveLookupContext, AgentWorkspaceLookupContextResolver.failClosedLookupContext)

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "working-dirs-root-projection-test",
            tabID: previousTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )

        let service = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        await service.prepareDomainTools()
        let tools = await service.tools
        let bindContext = try XCTUnwrap(tools.first { $0.name == MCPGlobalToolName.bindContext })

        do {
            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await bindContext([
                    "op": .string("bind"),
                    "working_dirs": .string(root.path),
                    "create_if_missing": .bool(false)
                ])
            }
            XCTFail("Expected rootless active tab binding to fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Rootless Agent"), message)
            XCTAssertTrue(message.contains(rootlessTabID.uuidString), message)
            XCTAssertTrue(message.contains("does not have the requested root projection loaded"), message)
            XCTAssertTrue(message.contains("existing MCP binding was not changed"), message)
        }

        XCTAssertEqual(window.mcpServer.tabContextByConnectionID[connectionID]?.tabID, previousTabID)
    }

    @MainActor
    private func install(workspace: WorkspaceModel, in window: WindowState, reason: String) async throws {
        window.workspaceManager.workspaces = [workspace]
        let switchResult = await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: reason
        )
        XCTAssertTrue(switchResult.didSwitch)
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
    }

    @MainActor
    private func bindContextTool(
        for window: WindowState
    ) async throws -> (WindowRoutingService, RepoPromptApp.Tool) {
        let service = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        await service.prepareDomainTools()
        let tools = await service.tools
        return try (service, XCTUnwrap(tools.first { $0.name == MCPGlobalToolName.bindContext }))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingDirsBindRootProjectionTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func makeWorktreeBinding(
        logicalRoot: WorkspaceRootRecord,
        physicalRoot: WorkspaceRootRecord
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.standardizedFullPath,
            source: "test"
        )
    }
}

private actor WorkingDirsHydrationGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        if !started {
            started = true
            let pending = startWaiters
            startWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
