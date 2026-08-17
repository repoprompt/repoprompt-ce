import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class WorkingDirsBindRootProjectionTests: XCTestCase {
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
}
