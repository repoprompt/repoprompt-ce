import AppKit
import Foundation
import MCP
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class MCPAgentModeSessionNamingControlTests: XCTestCase {
    func testAgentModeSetStatusEffectiveSurfaceCoversEveryProviderAndRole() async throws {
        let manager = ServerNetworkManager.shared
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()
        let catalogService = window.mcpServer.windowMCPToolCatalogService
        ServiceRegistry.register(catalogService)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Effective naming surface",
            repoPaths: [],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpAgentModeSetStatusEffectiveSurfaceTests"
        )
        let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
        let roles: [AgentModelCatalog.TaskLabelKind?] =
            [nil] + AgentModelCatalog.TaskLabelKind.allCases.map(Optional.some)

        do {
            for agent in AgentProviderKind.allCases {
                for role in roles {
                    let runID = UUID()
                    let connectionID = UUID()
                    let spec = MCPBootstrapLeaseSpec.agentMode(
                        tabID: tabID,
                        runID: runID,
                        gateID: UUID(),
                        windowID: window.windowID,
                        agent: agent,
                        taskLabelKind: role
                    )
                    let additionalTools = spec.additionalTools ?? []
                    let isPolicyGranted = !MCPPolicyGatedTools.names.contains(MCPWindowToolName.setStatus)
                        || additionalTools.contains(MCPWindowToolName.setStatus)
                    let isEffectivelyAdvertised =
                        spec.purpose == .agentModeRun
                            && !spec.restrictedTools.contains(MCPWindowToolName.setStatus)
                            && isPolicyGranted
                            && AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                                toolName: MCPWindowToolName.setStatus,
                                taskLabelKind: role,
                                allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools
                            )

                    XCTAssertEqual(spec.purpose, .agentModeRun, "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")")
                    XCTAssertEqual(
                        additionalTools,
                        AgentModeMCPPolicyInstaller.additionalTools(for: agent),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )
                    XCTAssertTrue(
                        additionalTools.contains(MCPWindowToolName.setStatus),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )

                    let clientName = try XCTUnwrap(spec.clientName)
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: spec.windowID,
                        restrictedTools: spec.restrictedTools,
                        oneShot: spec.oneShot,
                        reason: spec.reason,
                        ttl: spec.ttl,
                        tabID: spec.tabID,
                        runID: spec.runID,
                        additionalTools: spec.additionalTools,
                        purpose: spec.purpose,
                        taskLabelKind: spec.taskLabelKind,
                        allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
                        requiresExpectedAgentPID: spec.requiresExpectedAgentPID
                    )
                    if spec.requiresExpectedAgentPID {
                        await manager.registerExpectedAgentPID(
                            getpid(),
                            for: clientName,
                            runID: runID
                        )
                    }
                    let appliedPolicy = await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: clientName,
                        sessionKey: "naming-surface-\(runID.uuidString)",
                        pidGateTimeout: 0.25,
                        requireRunRouting: false
                    )
                    XCTAssertEqual(
                        appliedPolicy.outcome,
                        "applied",
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )
                    let advertisedTools = try await manager.debugListToolNames(
                        for: connectionID,
                        hydratePersistedPolicy: false
                    )
                    XCTAssertTrue(
                        isEffectivelyAdvertised && advertisedTools.contains(MCPWindowToolName.setStatus),
                        "agent=\(agent.rawValue), role=\(role?.rawValue ?? "nil")"
                    )

                    if spec.requiresExpectedAgentPID {
                        await manager.clearExpectedAgentPID(
                            getpid(),
                            for: clientName,
                            runID: runID
                        )
                    }
                    await manager.clearClientConnectionPolicy(
                        for: clientName,
                        windowID: window.windowID,
                        runID: runID
                    )
                    await manager.removeConnection(connectionID)
                    await manager.cleanupRunRoutingState(
                        for: runID,
                        windowID: window.windowID
                    )
                }
            }
        } catch {
            ServiceRegistry.unregister(catalogService)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }

        ServiceRegistry.unregister(catalogService)
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testSetStatusReturnsOnlyVerifiedCanonicalNameAndRejectsMissingOrBlankInput() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAgentModeSessionNamingControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Naming Control",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "mcpAgentModeSessionNamingControlTests"
            )
            let tabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
            let selectedTabID = window.promptManager.activeComposeTabID

            let result = try await MCPAgentSessionControlToolProvider.executeSetStatus(
                args: ["session_name": .string("  Canonical   Session  ")],
                targetWindow: window,
                tabID: tabID
            )
            let object = try XCTUnwrap(result.objectValue)
            XCTAssertEqual(object["ok"]?.boolValue, true)
            XCTAssertEqual(object["session_name_applied"]?.boolValue, true)
            XCTAssertEqual(object["session_name"]?.stringValue, "Canonical Session")
            XCTAssertEqual(window.workspaceManager.composeTabName(with: tabID), "Canonical Session")
            XCTAssertEqual(
                window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.name,
                "Canonical Session"
            )
            XCTAssertEqual(window.promptManager.activeComposeTabID, selectedTabID)

            for invalidArguments: [String: Value] in [
                [:],
                ["session_name": .string("  \n  ")]
            ] {
                do {
                    _ = try await MCPAgentSessionControlToolProvider.executeSetStatus(
                        args: invalidArguments,
                        targetWindow: window,
                        tabID: tabID
                    )
                    XCTFail("Expected invalid session_name to fail")
                } catch {
                    XCTAssertTrue(error is MCPError)
                }
                XCTAssertEqual(window.workspaceManager.composeTabName(with: tabID), "Canonical Session")
            }
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }

        await cleanup(window: window, rootURL: rootURL)
    }

    func testPublicSetStatusImmediatelyRenamesFreshBackgroundAgentWithoutChangingForeground() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAgentModeSessionNamingControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(appCoreContainer: RepoPromptAppCoreContainer(debugOverride: .core))
        let nsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.attachWindow(nsWindow)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        let connectionManager = ServerNetworkManager.shared
        let toolConnectionID = UUID()
        let controlRunID = UUID()
        addTeardownBlock { @MainActor in
            window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
            window.mcpServer.setRequestMetadataOverrideForTesting(nil)
            await connectionManager.cleanupRunRoutingState(
                for: controlRunID,
                windowID: window.windowID
            )
            await connectionManager.removeConnection(toolConnectionID)
            window.attachWindow(nil)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let client = try XCTUnwrap(window.workspaceSessionCommandClient)
        let foregroundTabID = UUID()
        let workspace = WorkspaceModel(
            name: "Fresh background naming",
            repoPaths: [],
            customStoragePath: rootURL,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: foregroundTabID, name: "Foreground decoy")],
            activeComposeTabID: foregroundTabID
        )
        let workspaceResult = await client.execute(
            .workspace(.create(workspace, makeActive: false)),
            source: WorkspaceSessionCommandSource(kind: "test-fresh-background-set-status-workspace")
        )
        guard case .committed = workspaceResult else {
            return XCTFail("Expected workspace installation, got \(workspaceResult)")
        }
        let installedWorkspace = try XCTUnwrap(window.workspaceManager.workspace(withID: workspace.id))
        let switchResult = await window.workspaceManager.switchWorkspace(
            to: installedWorkspace,
            saveState: false,
            reason: "test-fresh-background-set-status-workspace"
        )
        XCTAssertEqual(switchResult, .switched)

        let startConnectionID = UUID()
        window.mcpServer.setRequestMetadataOverrideForTesting(.init(
            connectionID: startConnectionID,
            clientName: "fresh-background-set-status-start",
            windowID: window.windowID,
            runPurpose: .unknown,
            explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                connectionID: startConnectionID,
                toolName: MCPWindowToolName.agentRun,
                windowID: window.windowID,
                windowStateIdentity: ObjectIdentifier(window),
                serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                runtimeAdapterTicket: nil,
                provenance: .hiddenWindowArgument
            )
        ))
        window.apiSettingsViewModel.isCodexConnected = true
        window.mcpServer.setAgentRunDispatchOverrideForTesting { _, tabID, _, _, viewModel in
            let session = viewModel.session(for: tabID)
            session.runID = controlRunID
            session.runState = .running
            return .startedRun
        }

        let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
            "op": .string("start"),
            "message": .string("Name this fresh background session."),
            "model_id": .string("explore"),
            "session_name": .string("Fresh background"),
            "detach": .bool(true),
            "timeout": .int(0)
        ])
        let startObject = try XCTUnwrap(startValue.objectValue)
        let sessionID = try XCTUnwrap(
            startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
        let backgroundTabID = try XCTUnwrap(
            startObject["session"]?.objectValue?["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
        XCTAssertEqual(window.promptManager.activeComposeTabID, foregroundTabID)

        await connectionManager.debugSeedRunPolicyState(
            runID: controlRunID,
            windowID: window.windowID,
            workspaceID: workspace.id,
            tabID: backgroundTabID,
            restrictedTools: [],
            additionalTools: [MCPWindowToolName.setStatus],
            purpose: .agentModeRun
        )
        await connectionManager.debugSeedConnectionRunRouting(
            connectionID: toolConnectionID,
            runID: controlRunID,
            purpose: .agentModeRun,
            windowID: window.windowID
        )
        try window.mcpServer.bindTabForConnection(
            connectionID: toolConnectionID,
            clientName: "fresh-background-set-status-tool",
            tabID: backgroundTabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        window.mcpServer.setRequestMetadataOverrideForTesting(.init(
            connectionID: toolConnectionID,
            clientName: "fresh-background-set-status-tool",
            windowID: window.windowID,
            runPurpose: .agentModeRun
        ))

        window.requestWindowTitleUpdate(reason: .explicit)
        await Task.yield()
        await Task.yield()
        let foregroundWindowTitle = window.displayedWindowTitle
        let foregroundNSWindowTitle = nsWindow.title
        let tools = await window.mcpServer.windowMCPTools
        let setStatus = try XCTUnwrap(
            tools.first(where: { $0.name == MCPWindowToolName.setStatus })
        )
        let renamedTitle = "Immediate background receipt"
        let result = try await ServerNetworkManager.withConnectionID(toolConnectionID) {
            try await setStatus(["session_name": .string(renamedTitle)])
        }
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["ok"]?.boolValue, true)
        XCTAssertEqual(object["context_id"]?.stringValue, backgroundTabID.uuidString)
        XCTAssertEqual(object["session_name"]?.stringValue, renamedTitle)
        XCTAssertEqual(window.promptManager.activeComposeTabID, foregroundTabID)
        XCTAssertEqual(window.workspaceManager.composeTabName(with: backgroundTabID), renamedTitle)
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == backgroundTabID })?.name,
            renamedTitle
        )
        XCTAssertEqual(
            window.agentModeViewModel.sidebarSessions(
                for: window.promptManager.currentComposeTabs
            ).first(where: { $0.tabID == backgroundTabID })?.title,
            renamedTitle
        )
        await window.agentModeViewModel.flushSave(for: backgroundTabID)
        XCTAssertEqual(window.agentModeViewModel.test_ownerValidatedSessionIndex[sessionID]?.name, renamedTitle)
        let persisted = try await AgentSessionDataService.shared.loadAgentSession(
            id: sessionID,
            for: XCTUnwrap(window.workspaceManager.workspace(withID: workspace.id))
        )
        XCTAssertEqual(persisted?.name, renamedTitle)

        await Task.yield()
        await Task.yield()
        XCTAssertEqual(window.displayedWindowTitle, foregroundWindowTitle)
        XCTAssertEqual(nsWindow.title, foregroundNSWindowTitle)
    }

    private func cleanup(window: WindowState, rootURL: URL) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
