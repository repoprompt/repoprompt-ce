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
            liveB.setWorkspaceInstanceAssignment(
                WorkspaceInstanceAssignment(workspaceID: workspaceB.id, number: liveBInstanceNumber)
            )
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
            restoredA.setWorkspaceInstanceAssignment(
                WorkspaceInstanceAssignment(workspaceID: workspaceA.id, number: restoredAInstanceNumber)
            )
            XCTAssertEqual(restoredAInstanceNumber, persistedWorkspaceInstanceNumber)
            let restoredAToolsEnabled = await restoredA.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(restoredAToolsEnabled)

            // A is restored under a different numeric ID; the same real tool call now
            // reaches that window rather than falling back to B. File tools still require
            // a bound tab context, which this routing-only fixture does not create.
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
            XCTAssertEqual(restored.isError, true)
            XCTAssertTrue(toolText(restored).contains("No tab context is bound for file_tool_lookup_scope"))
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

        /// #1112: a registered window's real switch is held after the target ID is published and
        /// before its listener assigns the number. Live capture and MCP route recording made there
        /// pair the target with nil, never the outgoing number, then record the assigned number.
        @MainActor
        func testLiveCaptureAndRouteRecordQualifyInstanceNumberAcrossAssignmentGap() async throws {
            // Already normalized: route records are stored under `MCPClientIdentity.storageKey`.
            let clientName = "issue1112-routing-gap-tests"
            // Real manager persistence writes windowSessions.json; refuse to run outside the sandbox.
            _ = try WorkspaceTestProcessSandbox.validate()
            let sessionURL = WindowSessionStore.sessionFileURL()
            let previousSession = try? Data(contentsOf: sessionURL)
            addTeardownBlock {
                if let previousSession {
                    try? previousSession.write(to: sessionURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: sessionURL)
                }
            }
            let sessionKey = "issue-1112-gap-\(UUID().uuidString)"
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("issue-1112-gap-\(UUID().uuidString)", isDirectory: true)
            for name in ["outgoing", "target"] {
                try FileManager.default.createDirectory(
                    at: rootURL.appendingPathComponent(name), withIntermediateDirectories: true
                )
            }
            let outgoing = workspace(name: "Outgoing", root: rootURL.appendingPathComponent("outgoing").path)
            let target = workspace(name: "Target", root: rootURL.appendingPathComponent("target").path)
            let manager = ServerNetworkManager.shared
            let previousWindows = WindowStatesManager.shared.allWindows
            addTeardownBlock { @MainActor in
                await manager.debugRestorePersistedRoutingFixtureForTesting()
                WindowStatesManager.shared.allWindows = previousWindows
                try? FileManager.default.removeItem(at: rootURL)
            }
            await manager.debugInstallPersistedRoutingFixtureForTesting(records: [])
            WindowStatesManager.shared.allWindows = []
            // Exact numbering: Outgoing=3 (two earlier instances), Target=1; restored afterwards.
            let previousAllocator = WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting()
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting(previousAllocator)
            }
            for _ in 1 ... 2 {
                WindowStatesManager.shared.recordWorkspaceSwitch(
                    forWindowID: WindowState.reserveWindowIDForTesting(),
                    to: outgoing
                )
            }
            let window = try await makeWindow(activeWorkspace: outgoing)
            addTeardownBlock { @MainActor in
                window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            WindowStatesManager.shared.registerWindowState(window)
            let outgoingNumber = try XCTUnwrap(window.workspaceInstanceNumber(for: outgoing.id))
            XCTAssertEqual(outgoingNumber, 3)
            let connection = try await makeProductionMCPConnection(
                networkManager: manager,
                clientName: clientName,
                sessionToken: sessionKey
            )
            addTeardownBlock { await connection.cleanup() }
            let outgoingIdentity = await recordedIdentity(window, connection, clientName: clientName)
            XCTAssertEqual(outgoingIdentity.entry?.workspaceInstanceNumber, outgoingNumber)
            XCTAssertEqual(outgoingIdentity.record?.lastWorkspaceInstanceNumber, outgoingNumber)

            // Stable target affinities: one paired with the number this window carries into the gap,
            // one with the target's own settled number.
            let staleClient = "issue1112-stale-pair"
            let staleKey = "issue-1112-stale-\(UUID().uuidString)"
            let settledClient = "issue1112-settled-pair"
            let settledKey = "issue-1112-settled-\(UUID().uuidString)"
            await manager.debugInstallPersistedRoutingFixtureForTesting(records: [
                routingRecord(
                    clientName: staleClient,
                    sessionKey: staleKey,
                    windowID: window.windowID + 10000,
                    workspaceID: target.id,
                    instanceNumber: outgoingNumber
                ),
                routingRecord(
                    clientName: settledClient,
                    sessionKey: settledKey,
                    windowID: window.windowID + 10001,
                    workspaceID: target.id,
                    instanceNumber: 1
                )
            ])

            window.workspaceManager.workspaces.append(target)
            var gapIdentity: (entry: WindowSessionEntry?, record: MCPRoutingState.ClientRecord?)?
            var gapWindowObject: [String: Any]?
            var gapStaleRoute: Int?
            var gapSettledRoute: Int?
            window.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { [self] id in
                guard id == target.id else { return }
                XCTAssertEqual(window.workspaceManager.activeWorkspaceID, target.id)
                gapIdentity = await recordedIdentity(window, connection, clientName: clientName)
                gapWindowObject = await debugWindowObject(window, connection, clientName: clientName)
                gapStaleRoute = await manager.debugPreferredWindowIDForTesting(clientName: staleClient, sessionKey: staleKey)
                gapSettledRoute = await manager.debugPreferredWindowIDForTesting(
                    clientName: settledClient,
                    sessionKey: settledKey
                )
            }
            _ = await window.workspaceManager.switchWorkspace(
                to: target,
                saveState: false,
                reason: "persistedMCPRoutingIdentityGapTest"
            )
            let gap = try XCTUnwrap(gapIdentity)
            XCTAssertEqual(gap.entry?.workspaceID, target.id)
            XCTAssertNil(gap.entry?.workspaceInstanceNumber, "persisted entry")
            XCTAssertEqual(gap.record?.lastWorkspaceID, target.id)
            XCTAssertNotNil(gap.record)
            XCTAssertNil(gap.record?.lastWorkspaceInstanceNumber, "routing record")
            XCTAssertEqual(gapWindowObject?["workspace_id"] as? String, target.id.uuidString)
            XCTAssertTrue(gapWindowObject?["workspace_instance_number"] is NSNull, "\(String(describing: gapWindowObject))")
            XCTAssertNil(gapStaleRoute, "the gap window must not satisfy a target pair carrying the outgoing number")
            XCTAssertNil(gapSettledRoute, "the gap window has no target number yet")

            let targetNumber = try XCTUnwrap(window.workspaceInstanceNumber(for: target.id))
            XCTAssertEqual(targetNumber, 1)
            let settled = await recordedIdentity(window, connection, clientName: clientName)
            XCTAssertEqual(settled.entry?.workspaceID, target.id)
            XCTAssertEqual(settled.entry?.workspaceInstanceNumber, targetNumber)
            XCTAssertEqual(settled.record?.lastWorkspaceID, target.id)
            XCTAssertEqual(settled.record?.lastWorkspaceInstanceNumber, targetNumber)
            let settledWindowObject = await debugWindowObject(window, connection, clientName: clientName)
            XCTAssertEqual(settledWindowObject?["workspace_instance_number"] as? Int, targetNumber)
            let settledRoute = await manager.debugPreferredWindowIDForTesting(
                clientName: settledClient,
                sessionKey: settledKey
            )
            XCTAssertEqual(settledRoute, window.windowID)
            let settledStaleRoute = await manager.debugPreferredWindowIDForTesting(
                clientName: staleClient,
                sessionKey: staleKey
            )
            XCTAssertNil(settledStaleRoute)

            // Restoring the persisted entries seeds the outgoing number but nothing for the target,
            // whose gap entry carried nil rather than the outgoing number.
            let restored = try WindowSessionSnapshot(
                version: 4,
                windows: [XCTUnwrap(outgoingIdentity.entry), XCTUnwrap(gap.entry)]
            )
            let liveAllocator = WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting()
            WindowStatesManager.shared.preseedInstanceNumberStateForTesting(from: restored)
            let restoredTarget = WindowStatesManager.shared.recordWorkspaceSwitch(
                forWindowID: WindowState.reserveWindowIDForTesting(),
                to: target
            )
            let restoredOutgoing = WindowStatesManager.shared.recordWorkspaceSwitch(
                forWindowID: WindowState.reserveWindowIDForTesting(),
                to: outgoing
            )
            WindowStatesManager.shared.replaceInstanceAllocatorStateForTesting(liveAllocator)
            XCTAssertEqual(restoredTarget, 1)
            XCTAssertEqual(restoredOutgoing, 3)
        }

        /// The diagnostics routing snapshot's object for `window`.
        @MainActor
        private func debugWindowObject(
            _ window: WindowState,
            _ connection: Issue862ProductionMCPConnection,
            clientName: String
        ) async -> [String: Any]? {
            let payload = await ServerNetworkManager.shared.debugRoutingSnapshotPayload(
                currentConnectionID: connection.connectionID,
                requestedConnectionID: nil,
                clientNameFilter: clientName,
                includeRecords: false,
                includeWindows: true
            )
            return (payload["windows"] as? [[String: Any]])?.first { $0["window_id"] as? Int == window.windowID }
        }

        /// The entry the manager persists for `window` (decoded from windowSessions.json after a real
        /// `persistWindowSessionImmediately`) and the MCP route record written for it right now.
        @MainActor
        private func recordedIdentity(
            _ window: WindowState,
            _ connection: Issue862ProductionMCPConnection,
            clientName: String
        ) async -> (entry: WindowSessionEntry?, record: MCPRoutingState.ClientRecord?) {
            let sessionURL = WindowSessionStore.sessionFileURL()
            try? FileManager.default.removeItem(at: sessionURL)
            await WindowStatesManager.shared.persistWindowSessionImmediately(reason: "issue1112RoutingGapTest")
            let entry = (try? Data(contentsOf: sessionURL))
                .flatMap { try? JSONDecoder().decode(WindowSessionSnapshot.self, from: $0) }?
                .windows.first
            let payload = await ServerNetworkManager.shared.debugSeedRoutingAffinityPayload(
                connectionID: connection.connectionID,
                windowID: window.windowID
            )
            XCTAssertEqual(payload["persisted"] as? Bool, true, "\(payload)")
            let records = await ServerNetworkManager.shared.debugRoutingRecordsForTesting(clientName: clientName)
            return (entry, records.first)
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
