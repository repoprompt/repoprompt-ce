import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class BindContextRoutingAuthorityTests: XCTestCase {
    #if DEBUG
        @MainActor
        func testExplicitBindThenContextIDRoutedToolUsesSameCompositeContext() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-routing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: rootURL)
            }

            let contextID = UUID()
            let staleMatch = workspace(name: "Stored Target", root: rootURL.path, contextID: contextID)
            let unrelated = workspace(
                name: "Active Unrelated",
                root: rootURL.appendingPathComponent("unrelated").path,
                contextID: UUID()
            )
            let activeTarget = workspace(name: "Active Target", root: rootURL.path, contextID: contextID)
            let replacementActive = workspace(
                name: "Replacement Active",
                root: rootURL.appendingPathComponent("replacement").path,
                contextID: UUID()
            )
            let orderedWindows = [makeWindowInstance(), makeWindowInstance()].sorted { $0.windowID < $1.windowID }
            let staleWindow = orderedWindows[0]
            let targetWindow = orderedWindows[1]
            try await configureWindow(staleWindow, activeWorkspace: unrelated, savedWorkspaces: [staleMatch])
            try await configureWindow(targetWindow, activeWorkspace: activeTarget)
            _ = installWindows(orderedWindows)
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let staleToolsEnabled = await staleWindow.mcpServer.setWindowToolsEnabled(true)
            let targetToolsEnabled = await targetWindow.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(staleToolsEnabled)
            XCTAssertTrue(targetToolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await staleWindow.mcpServer.setWindowToolsEnabled(false)
                _ = await targetWindow.mcpServer.setWindowToolsEnabled(false)
            }

            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let bindResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(bindResult.isError, true, toolText(bindResult))

            let boundBeforeCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundBeforeCall.windowID, targetWindow.windowID)
            XCTAssertEqual(boundBeforeCall.workspaceID, activeTarget.id)
            XCTAssertEqual(boundBeforeCall.tabID, contextID)
            XCTAssertTrue(boundBeforeCall.explicitlyBound)
            XCTAssertNil(boundBeforeCall.runID)

            let routedResult = try await connection.client.callTool(name: "workspace_context", arguments: [
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(routedResult.isError, true, toolText(routedResult))

            try await configureWindow(
                targetWindow,
                activeWorkspace: replacementActive,
                savedWorkspaces: [activeTarget]
            )
            XCTAssertEqual(targetWindow.workspaceManager.activeWorkspaceID, replacementActive.id)

            let routedAfterWorkspaceSwitch = try await connection.client.callTool(
                name: "workspace_context",
                arguments: [
                    "context_id": .string(contextID.uuidString),
                    "_rawJSON": .bool(true)
                ]
            )
            XCTAssertNotEqual(
                routedAfterWorkspaceSwitch.isError,
                true,
                toolText(routedAfterWorkspaceSwitch)
            )

            let statusResult = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("status"),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(statusResult.isError, true, toolText(statusResult))
            let statusData = try XCTUnwrap(toolText(statusResult).data(using: .utf8))
            let status = try JSONDecoder().decode(BindContextResponse.self, from: statusData)
            XCTAssertEqual(status.binding.windowID, targetWindow.windowID)
            XCTAssertEqual(status.binding.workspaceID, activeTarget.id)
            XCTAssertEqual(status.binding.contextID, contextID)
            XCTAssertTrue(status.binding.explicit)
            XCTAssertFalse(status.binding.runScoped)

            let boundAfterCall = targetWindow.mcpServer.connectionBindingSnapshot(
                forConnection: connection.connectionID
            )
            XCTAssertEqual(boundAfterCall.windowID, boundBeforeCall.windowID)
            XCTAssertEqual(boundAfterCall.workspaceID, boundBeforeCall.workspaceID)
            XCTAssertEqual(boundAfterCall.tabID, boundBeforeCall.tabID)
            XCTAssertTrue(boundAfterCall.explicitlyBound)
            XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)

            await connection.cleanup()
            let networkManagerRunningAfterCleanup = await ServerNetworkManager.shared.isRunning()
            XCTAssertEqual(networkManagerRunningAfterCleanup, connection.wasNetworkManagerRunning)
        }
    #endif

    @MainActor
    func testContextIDBindIgnoresPreferredInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let targetWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([staleWindow, targetWindow])

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )

        XCTAssertEqual(resolved.windowID, targetWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, target.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, target.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindDeterministicFallbackExcludesInactiveWorkspaceMatch() async throws {
        let contextID = UUID()
        let root = "/tmp/repoprompt-bind-target"
        let inactiveDuplicate = workspace(name: "Stored Target", root: root, contextID: contextID)
        let firstTarget = workspace(name: "First Active Target", root: root, contextID: contextID)
        let secondTarget = workspace(name: "Second Active Target", root: root, contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [inactiveDuplicate])
        let firstTargetWindow = try await makeWindow(activeWorkspace: firstTarget)
        let secondTargetWindow = try await makeWindow(activeWorkspace: secondTarget)
        let service = installWindows([staleWindow, firstTargetWindow, secondTargetWindow])
        let expectedWindow = try XCTUnwrap(
            [firstTargetWindow, secondTargetWindow].min { $0.windowID < $1.windowID }
        )
        let expectedWorkspace = expectedWindow.windowID == firstTargetWindow.windowID ? firstTarget : secondTarget

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: nil
        )

        XCTAssertEqual(resolved.windowID, expectedWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, expectedWorkspace.id)
        XCTAssertEqual(resolved.tabID, contextID)
        XCTAssertEqual(resolved.repoPaths, expectedWorkspace.repoPaths)
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    @MainActor
    func testContextIDBindOnlyInactiveMatchFailsClosed() async throws {
        let contextID = UUID()
        let target = workspace(name: "Target", root: "/tmp/repoprompt-bind-target", contextID: contextID)
        let unrelated = workspace(name: "Unrelated", root: "/tmp/repoprompt-bind-unrelated", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let service = installWindows([staleWindow])

        XCTAssertThrowsError(try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("No open RepoPrompt window actively shows context_id"), message)
        }
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
    }

    #if DEBUG
        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }
    #endif

    @MainActor
    private func makeWindowInstance() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState()
    }

    @MainActor
    private func configureWindow(
        _ window: WindowState,
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws {
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [activeWorkspace] + savedWorkspaces
        _ = await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "bindContextRoutingAuthorityTest"
        )
        guard window.workspaceManager.activeWorkspaceID == activeWorkspace.id else {
            throw BindContextRoutingFixtureError.workspaceActivationFailed
        }
    }

    #if DEBUG
        private func makeProductionMCPConnection() async throws -> ProductionMCPConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }

            let connectionID = UUID()
            let sessionToken = "bind-routing-\(UUID().uuidString)"
            let clientName = "BindContextRoutingAuthorityTests"
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: descriptors[0],
                parentManager: networkManager
            )
            descriptors[0] = -1
            let clientTransport = try UnixSocketMCPTransport(
                connectedFD: descriptors[1],
                connectionID: connectionID,
                correlationConnectionID: sessionToken
            )
            descriptors[1] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)

            do {
                try await connectionManager.start { $0.name == clientName }
                let client = Client(name: clientName, version: "1.0")
                _ = try await client.connect(transport: clientTransport)
                return ProductionMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    wasNetworkManagerRunning: wasNetworkManagerRunning
                )
            } catch {
                await clientTransport.disconnect()
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
                throw error
            }
        }
    #endif

    private func workspace(name: String, root: String, contextID: UUID) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [root],
            composeTabs: [ComposeTabState(id: contextID, name: "Context")],
            activeComposeTabID: contextID
        )
    }

    @MainActor
    private func makeWindow(
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws -> WindowState {
        let window = makeWindowInstance()
        try await configureWindow(
            window,
            activeWorkspace: activeWorkspace,
            savedWorkspaces: savedWorkspaces
        )
        return window
    }

    @MainActor
    private func installWindows(_ windows: [WindowState]) -> WindowRoutingService {
        let previousWindows = WindowStatesManager.shared.allWindows
        WindowStatesManager.shared.allWindows = windows
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.allWindows = previousWindows
        }
        return WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
    }
}

#if DEBUG
    private struct ProductionMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            let networkManager = ServerNetworkManager.shared
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif

private enum BindContextRoutingFixtureError: Error {
    case workspaceActivationFailed
}
