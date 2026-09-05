#if DEBUG
    import Darwin
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import XCTest

    final class PersistedMCPRoutingIdentityTests: XCTestCase {
        @MainActor
        func testPreCallBindingRejectsUnrelatedWindowThenRestoresStableWorkspace() async throws {
            let clientName = "Issue862RoutingBoundaryTests"
            let sessionKey = "issue-862-boundary-\(UUID().uuidString)"
            let workspaceA = workspace(name: "Restored A", root: "/tmp/issue-862-a")
            let workspaceB = workspace(name: "Unrelated B", root: "/tmp/issue-862-b")
            let manager = ServerNetworkManager.shared
            let previousWindows = WindowStatesManager.shared.allWindows
            // Register first so XCTest runs this final restoration after the connection
            // and each owned window have finished teardown while routing persistence is suppressed.
            addTeardownBlock { @MainActor in
                await manager.debugRestorePersistedRoutingFixtureForTesting()
                WindowStatesManager.shared.allWindows = previousWindows
            }
            // Snapshot and suppress shared routing persistence before any window setup can mutate it.
            await manager.debugInstallPersistedRoutingFixtureForTesting(records: [])
            WindowStatesManager.shared.allWindows = []
            let liveB = try await makeWindow(activeWorkspace: workspaceB)
            addTeardownBlock { @MainActor in
                _ = await liveB.mcpServer.setWindowToolsEnabled(false)
                WindowStatesManager.shared.allWindows.removeAll { $0 === liveB }
                WindowStatesManager.shared.clearInstanceAssignment(forWindowID: liveB.windowID)
                if !liveB.isClosing {
                    await liveB.tearDown()
                }
            }
            let restoredA = try await makeWindow(activeWorkspace: workspaceA)
            addTeardownBlock { @MainActor in
                _ = await restoredA.mcpServer.setWindowToolsEnabled(false)
                WindowStatesManager.shared.allWindows.removeAll { $0 === restoredA }
                WindowStatesManager.shared.clearInstanceAssignment(forWindowID: restoredA.windowID)
                if !restoredA.isClosing {
                    await restoredA.tearDown()
                }
            }
            WindowStatesManager.shared.allWindows = [liveB]
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let liveBToolsEnabled = await liveB.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(liveBToolsEnabled)

            let persistedWorkspaceInstanceNumber = 1
            let record = routingRecord(
                clientName: clientName,
                sessionKey: sessionKey,
                windowID: liveB.windowID,
                workspaceID: workspaceA.id,
                instanceNumber: persistedWorkspaceInstanceNumber
            )
            await manager.debugInstallPersistedRoutingFixtureForTesting(
                records: [record],
                cachedWindowIDs: [sessionKey: liveB.windowID]
            )
            let liveBInstanceNumber = try XCTUnwrap(
                WindowStatesManager.shared.recordWorkspaceSwitch(
                    forWindowID: liveB.windowID,
                    to: workspaceB
                )
            )
            liveB.workspaceInstanceNumber = liveBInstanceNumber
            await manager.debugSetRoutingWindowSnapshotForTesting([
                MCPRoutingWindowSnapshot(
                    workspaceID: workspaceB.id,
                    instanceNumber: liveBInstanceNumber,
                    windowID: liveB.windowID
                )
            ])

            let connection = try await makeProductionMCPConnection(
                networkManager: manager,
                clientName: clientName,
                sessionToken: sessionKey
            )
            addTeardownBlock { await connection.cleanup() }

            // Exercise the ordinary pre-call binding boundary before the tool decision.
            _ = try await connection.client.listTools()
            let selectedAfterPreCallBinding = await manager.selectedWindow(for: connection.connectionID)
            XCTAssertNil(selectedAfterPreCallBinding)
            XCTAssertNil(liveB.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID).windowID)

            let rejected = try await connection.client.callTool(
                name: "get_file_tree",
                arguments: ["type": .string("roots"), "_rawJSON": .bool(true)]
            )
            XCTAssertEqual(rejected.isError, true, toolText(rejected))
            XCTAssertTrue(toolText(rejected).contains("workspace routing affinity"), toolText(rejected))
            let selectedAfterRejectedCall = await manager.selectedWindow(for: connection.connectionID)
            XCTAssertNil(selectedAfterRejectedCall)
            let recordsBeforeRestore = await manager.debugRoutingRecordsForTesting(clientName: clientName)
            let retainedBeforeRestore = try XCTUnwrap(recordsBeforeRestore.first)
            XCTAssertEqual(retainedBeforeRestore.lastWorkspaceID, workspaceA.id)
            XCTAssertEqual(
                retainedBeforeRestore.lastWorkspaceInstanceNumber,
                persistedWorkspaceInstanceNumber
            )
            XCTAssertNil(retainedBeforeRestore.lastWindowID)

            // Restore A through the same instance-number authority that production uses.
            // The allWindows list and enabled catalog provide the real live dispatch target
            // without registering a persistent window-session fixture.
            _ = await liveB.mcpServer.setWindowToolsEnabled(false)
            WindowStatesManager.shared.allWindows = []
            WindowStatesManager.shared.clearInstanceAssignment(forWindowID: liveB.windowID)
            liveB.beginClose()
            await liveB.tearDown()
            let restoredAInstanceNumber = try XCTUnwrap(
                WindowStatesManager.shared.recordWorkspaceSwitch(
                    forWindowID: restoredA.windowID,
                    to: workspaceA
                )
            )
            restoredA.workspaceInstanceNumber = restoredAInstanceNumber
            XCTAssertEqual(restoredAInstanceNumber, persistedWorkspaceInstanceNumber)
            let restoredAToolsEnabled = await restoredA.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(restoredAToolsEnabled)

            // A is restored under a different numeric ID; the same real tools/call now
            // reaches the stable target rather than falling back to B. Roots lookup is
            // window-scoped and needs no explicit context hint that could override affinity.
            WindowStatesManager.shared.allWindows = [restoredA]
            await manager.debugSetRoutingWindowSnapshotForTesting([
                MCPRoutingWindowSnapshot(
                    workspaceID: workspaceA.id,
                    instanceNumber: restoredAInstanceNumber,
                    windowID: restoredA.windowID
                )
            ])
            let restored = try await connection.client.callTool(
                name: "get_file_tree",
                arguments: ["type": .string("roots"), "_rawJSON": .bool(true)]
            )
            XCTAssertNotEqual(restored.isError, true, toolText(restored))
            let selectedAfterRestore = await manager.selectedWindow(for: connection.connectionID)
            XCTAssertEqual(selectedAfterRestore, restoredA.windowID)
            let recordsAfterRestore = await manager.debugRoutingRecordsForTesting(clientName: clientName)
            let retainedAfterRestore = try XCTUnwrap(recordsAfterRestore.first)
            XCTAssertEqual(retainedAfterRestore.lastWorkspaceID, workspaceA.id)
            XCTAssertEqual(
                retainedAfterRestore.lastWorkspaceInstanceNumber,
                restoredAInstanceNumber
            )
        }

        func testReusedNumericWindowIDDoesNotRouteWorkspaceAToLiveWorkspaceB() async {
            let clientName = "Issue862RoutingTests"
            let sessionKey = "issue-862-reused-window"
            let workspaceA = UUID()
            let workspaceB = UUID()
            let reusedWindowID = 17
            let manager = ServerNetworkManager()
            let record = routingRecord(
                clientName: clientName,
                sessionKey: sessionKey,
                windowID: reusedWindowID,
                workspaceID: workspaceA,
                instanceNumber: 1
            )

            await manager.debugInstallPersistedRoutingFixtureForTesting(
                records: [record],
                cachedWindowIDs: [sessionKey: reusedWindowID]
            )
            await manager.debugSetRoutingWindowSnapshotForTesting([
                MCPRoutingWindowSnapshot(
                    workspaceID: workspaceB,
                    instanceNumber: 1,
                    windowID: reusedWindowID
                )
            ])

            let selectedWindowID = await manager.debugPreferredWindowIDForTesting(
                clientName: clientName,
                sessionKey: sessionKey
            )

            XCTAssertNil(selectedWindowID)
            let retainedRecord = await (manager.debugRoutingRecordsForTesting(clientName: clientName)).first
            XCTAssertEqual(retainedRecord?.lastWorkspaceID, workspaceA)
            XCTAssertEqual(retainedRecord?.lastWorkspaceInstanceNumber, 1)
            XCTAssertNil(retainedRecord?.lastWindowID)
        }

        func testStableWorkspaceARestoresUnderNewNumericWindowID() async {
            let clientName = "Issue862RoutingTests"
            let sessionKey = "issue-862-restored-window"
            let workspaceA = UUID()
            let oldWindowID = 17
            let restoredWindowID = 43
            let manager = ServerNetworkManager()
            let record = routingRecord(
                clientName: clientName,
                sessionKey: sessionKey,
                windowID: oldWindowID,
                workspaceID: workspaceA,
                instanceNumber: 1
            )

            await manager.debugInstallPersistedRoutingFixtureForTesting(
                records: [record],
                cachedWindowIDs: [sessionKey: oldWindowID]
            )
            await manager.debugSetRoutingWindowSnapshotForTesting([
                MCPRoutingWindowSnapshot(
                    workspaceID: workspaceA,
                    instanceNumber: 1,
                    windowID: restoredWindowID
                )
            ])

            let selectedWindowID = await manager.debugPreferredWindowIDForTesting(
                clientName: clientName,
                sessionKey: sessionKey
            )

            XCTAssertEqual(selectedWindowID, restoredWindowID)
            let retainedRecord = await (manager.debugRoutingRecordsForTesting(clientName: clientName)).first
            XCTAssertEqual(retainedRecord?.lastWorkspaceID, workspaceA)
            XCTAssertEqual(retainedRecord?.lastWorkspaceInstanceNumber, 1)
        }

        @MainActor
        private func makeWindow(activeWorkspace: WorkspaceModel) async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            window.workspaceManager.workspaces = [activeWorkspace]
            _ = await window.workspaceManager.switchWorkspace(
                to: activeWorkspace,
                saveState: false,
                reason: "persistedMCPRoutingIdentityTest"
            )
            return window
        }

        private func workspace(name: String, root: String) -> WorkspaceModel {
            WorkspaceModel(name: name, repoPaths: [root])
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func makeProductionMCPConnection(
            networkManager: ServerNetworkManager,
            clientName: String,
            sessionToken: String
        ) async throws -> Issue862ProductionMCPConnection {
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
                return Issue862ProductionMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    networkManager: networkManager,
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

        private func routingRecord(
            clientName: String,
            sessionKey: String,
            windowID: Int,
            workspaceID: UUID,
            instanceNumber: Int
        ) -> MCPRoutingState.ClientRecord {
            MCPRoutingState.ClientRecord(
                clientID: clientName,
                lastTransport: .network,
                sessionKey: sessionKey,
                lastWindowID: windowID,
                lastWorkspaceID: workspaceID,
                lastWorkspaceInstanceNumber: instanceNumber,
                lastConnectionUUID: UUID(),
                lastSeenAt: Date()
            )
        }
    }

    private struct Issue862ProductionMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let networkManager: ServerNetworkManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif
