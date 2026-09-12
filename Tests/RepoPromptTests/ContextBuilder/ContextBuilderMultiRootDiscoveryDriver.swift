import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderMultiRootDiscoveryDriver {
        let fixture: WorkspaceAuthorityRootTestFixture
        let polling = CodexModelPollingService(client: EmptyModelClient())
        var window: WindowState!
        var constructed = 0
        var streamStarts = 0
        var disposed = 0
        var teardownIDs: [UUID] = []
        var committed: MCPServerViewModel.ContextBuilderCommittedTabSnapshot?
        var committedByRunID: [UUID: MCPServerViewModel.ContextBuilderCommittedTabSnapshot] = [:]
        var afterCommittedTabSnapshotCaptured: (@MainActor @Sendable (
            UUID,
            MCPServerViewModel.ContextBuilderCommittedTabSnapshot
        ) async -> Void)?
        var providerValidationBody: (() async throws -> Void)?
        var providerValidationError: Error?
        var runSettlementCount = 0
        var providerWorkspacePaths: [String?] = []
        private var teardownWaiters: [CheckedContinuation<Void, Never>] = []
        private var bindingSessionIDs: [UUID] = []
        var connections: [RoutedConnection] = []
        private var parentRuns: [(lease: MCPBootstrapLease, runID: UUID, clientName: String)] = []
        var streamBody: ((UUID) async throws -> Void)?
        let teardown = XCTestExpectation(description: "real run teardown joined")
        private var previousWindows: [WindowState] = []
        private var networkWasRunning = false

        var vm: ContextBuilderAgentViewModel {
            window.contextBuilderAgentViewModel
        }

        var manager: WorkspaceManagerViewModel {
            window.workspaceManager
        }

        var files: WorkspaceFilesViewModel {
            window.workspaceFilesViewModel
        }

        var tabID: UUID {
            fixture.workspace.activeComposeTabID!
        }

        init(fixture: WorkspaceAuthorityRootTestFixture) {
            self.fixture = fixture
        }

        static func withDriver(
            rootNames: [String] = ["A", "B"], routedRuntime: Bool = false,
            _ body: @escaping (ContextBuilderMultiRootDiscoveryDriver) async throws -> Void
        ) async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: rootNames, configuration: { Array($0.prefix(2)) }) { fixture in
                let driver = ContextBuilderMultiRootDiscoveryDriver(fixture: fixture)
                let operation = {
                    do {
                        try await fixture.perform("discovery window setup") { try await driver.setUp() }
                        try await body(driver)
                        await driver.shutdown()
                    } catch {
                        await driver.shutdown()
                        throw error
                    }
                }
                if routedRuntime {
                    let globals = AppGlobalMCPServiceComposition.shared
                    let initialRegistration = globals.registrationScopeStateForTesting
                    let initialRuntimeID = AppDomainRuntimeComposition.shared.runtime.identity.runtimeID
                    defer {
                        XCTAssertEqual(globals.registrationScopeStateForTesting, initialRegistration)
                        XCTAssertEqual(AppDomainRuntimeComposition.shared.runtime.identity.runtimeID, initialRuntimeID)
                        XCTAssertNil(AppDomainRuntimeComposition.shared.runtimeForTesting)
                    }
                    try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(fixture.runtime, operation: operation)
                    XCTAssertNil(AppDomainRuntimeComposition.shared.runtimeForTesting)
                } else {
                    try await operation()
                }
            }
        }

        private func setUp() async throws {
            previousWindows = WindowStatesManager.shared.allWindows
            networkWasRunning = await ServerNetworkManager.shared.isRunning()
            window = WindowState(
                contextBuilderProviderFactory: { [unowned self] _, _, path in
                    constructed += 1
                    providerWorkspacePaths.append(path)
                    return Provider(driver: self)
                }, domainRuntime: fixture.runtime,
                keyManager: KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())),
                codexModelPollingService: polling,
                loadStoredAPISettingsDataOnInit: false
            )
            WindowStatesManager.shared.registerWindowState(window)
            await manager.awaitInitialized()
            let workspace = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
            _ = await manager.switchWorkspace(to: workspace, saveState: false, reason: "isolated discovery fixture")
            XCTAssertEqual(manager.activeWorkspaceID, workspace.id)
            let ticket = try XCTUnwrap(manager.requestRootReconciliation(workspaceID: workspace.id))
            _ = try await manager.awaitRootReconciliationCompletion(ticket: ticket)
            vm.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil, providerEventDisposition: nil,
                teardownCompleted: { [weak self] runID in
                    self?.teardownIDs.append(runID)
                    self?.teardown.fulfill()
                    let waiters = self?.teardownWaiters ?? []
                    self?.teardownWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                },
                validateContextBuilderProviders: { [weak self] in
                    do { try await self?.providerValidationBody?() }
                    catch { self?.providerValidationError = error }
                    self?.window.apiSettingsViewModel.isClaudeCodeConnected = true
                    self?.window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode])
                },
                committedTabSnapshotCaptured: { [weak self] runID, snapshot in
                    self?.committed = snapshot
                    self?.committedByRunID[runID] = snapshot
                },
                afterCommittedTabSnapshotCaptured: { [weak self] runID, snapshot in
                    await self?.afterCommittedTabSnapshotCaptured?(runID, snapshot)
                }
            ))
        }

        func resolve(
            tabID: UUID? = nil,
            bindings: [AgentSessionWorktreeBinding] = [],
            diagnosticSink: ContextBuilderWorkspaceReadinessDiagnosticSink? = nil,
            boundWorkspaceProbe: ContextBuilderBoundWorkspaceProbe = .init()
        ) async throws -> ContextBuilderWorkspaceContext {
            let resolvedTabID = tabID ?? self.tabID
            let snapshot = MCPServerViewModel.TabContextSnapshot(
                tabID: resolvedTabID, windowID: window.windowID, workspaceID: fixture.workspace.id,
                promptText: "SENSITIVE_DISCOVERY_PROMPT", selection: StoredSelection(), selectedMetaPromptIDs: [],
                tabName: "Fixture", runID: UUID(), activeAgentSessionID: UUID(),
                worktreeBindingState: .hydrated(bindings), explicitlyBound: true
            )
            if !bindings.isEmpty { bindingSessionIDs.append(snapshot.activeAgentSessionID!) }
            return try await ContextBuilderWorkspaceContext.resolve(
                from: snapshot, workspaceRepoPaths: fixture.workspace.repoPaths,
                workspaceDirectoryPath: fixture.workspaceURL.deletingLastPathComponent().path,
                workspaceManager: manager, readinessDiagnosticSink: diagnosticSink, boundWorkspaceProbe: boundWorkspaceProbe
            )
        }

        func authority(_ context: ContextBuilderWorkspaceContext) async throws -> ContextBuilderResolvedRunAuthority {
            let authority = try await vm.resolveMCPRunAuthority(
                identity: .init(workspaceID: fixture.workspace.id, tabID: context.tabID),
                nestedTabContext: context.nestedDiscoveryTabContext(runID: context.frozenTabContext.runID!),
                workspaceContext: context, responseType: nil
            )
            if let providerValidationError { throw providerValidationError }
            return authority
        }

        func run(
            _ context: ContextBuilderWorkspaceContext,
            authority: ContextBuilderResolvedRunAuthority,
            progress: ContextBuilderMCPProgressReporter? = nil
        ) async throws -> ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion {
            let token = try vm.beginMCPControlledRun(
                forTabID: context.tabID, workspaceID: fixture.workspace.id, responseType: nil, planModelName: nil
            )
            defer {
                runSettlementCount += 1
                vm.clearMCPControlledRun(forTabID: context.tabID, controlToken: token)
            }
            return try await vm.runContextBuilderForMCP(
                authority: authority, workspaceContext: context, mcpControlToken: token, progressReporter: progress
            )
        }

        func connectInvokingAgent(_ context: ContextBuilderWorkspaceContext) async throws -> RoutedConnection {
            await window.mcpServer.startServer()
            XCTAssertTrue(window.mcpServer.windowToolsEnabled)
            let runID = try XCTUnwrap(context.frozenTabContext.runID)
            let agent = AgentProviderKind.codexExec
            let name = try XCTUnwrap(agent.mcpClientNameHint)
            // A queued frozen invoking context owns session identity. A tabID policy would
            // intentionally recapture the ordinary compose tab, which has no Agent Mode session.
            let lease = MCPBootstrapLease(spec: .headless(
                runID: runID, gateID: UUID(), clientName: name, windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: agent),
                reason: "isolated invoking Agent Mode run", ttl: 30, purpose: .agentModeRun,
                requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
            ))
            parentRuns.append((lease, runID, name))
            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            window.mcpServer.installFrozenTabContext(clientID: nil, clientName: name, context: context.frozenTabContext)
            await ServerNetworkManager.shared.registerExpectedAgentPID(getpid(), for: name, runID: runID)
            let connection = try await connect(name: name, purpose: .agentModeRun)
            let routed = await lease.releaseWhenRouted(timeoutMs: 5000)
            XCTAssertTrue(routed)
            XCTAssertEqual(window.mcpServer.connectionBindingSnapshot(forConnection: connection.connectionID).runID, runID)
            XCTAssertEqual(try promotedSnapshot(for: connection).activeAgentSessionID, context.frozenTabContext.activeAgentSessionID)
            return connection
        }

        func invoke(using connection: RoutedConnection) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
            defer { runSettlementCount += 1 }
            return try await connection.client.callTool(name: "context_builder", arguments: [
                "instructions": .string("SENSITIVE_DISCOVERY_PROMPT"), "response_type": .string("clarify"), "_rawJSON": .bool(true)
            ])
        }

        func connectChild(runID: UUID) async throws -> RoutedConnection {
            let network = ServerNetworkManager.shared
            let name = AgentProviderKind.claudeCode.mcpClientNameHint!
            let policies = await network.debugPendingPolicySnapshot(for: name)
            XCTAssertEqual(policies.count(where: { $0.runID == runID && $0.purpose == .discoverRun }), 1)
            _ = try activeTabID(forRunID: runID)
            await network.registerExpectedAgentPID(getpid(), for: name, runID: runID)
            return try await connect(name: name, purpose: .discoverRun)
        }

        func installAdditionalTab(name: String = "Concurrent") async throws -> UUID {
            let createdTab = await window.promptManager.createBackgroundComposeTab(
                strategy: .blank,
                name: name
            )
            let tab = try XCTUnwrap(createdTab)
            // Tab creation saves through the window manager, not the fixture's manager.
            await manager.debugDrainScheduledSaves()
            try await fixture.settle()
            XCTAssertNotNil(manager.workspace(withID: fixture.workspace.id)?.composeTabs.first(where: { $0.id == tab.id }))
            let canonicalSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let canonicalWorkspace = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: canonical.document.documentBytes,
                fileURL: canonical.document.fileURL
            )
            XCTAssertNotNil(canonicalWorkspace.composeTabs.first(where: { $0.id == tab.id }))
            return tab.id
        }

        func activeTabID(forRunID runID: UUID) throws -> UUID {
            try XCTUnwrap(
                manager.activeWorkspace?.composeTabs
                    .map(\.id)
                    .first(where: { vm.activeRunIDForTesting(tabID: $0) == runID })
            )
        }

        func storedPrompt(tabID: UUID) -> String? {
            manager.workspace(withID: fixture.workspace.id)?.composeTabs
                .first(where: { $0.id == tabID })?
                .promptText
        }

        func connect(name: String, purpose: MCPRunPurpose) async throws -> RoutedConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer { for fd in descriptors where fd >= 0 {
                Darwin.close(fd)
            } }
            var peerPID: pid_t = 0
            var peerSize = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(descriptors[0], SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0, peerPID > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
            XCTAssertEqual(peerPID, getpid())
            let id = UUID()
            let token = "discovery-fixture-" + UUID().uuidString
            let network = ServerNetworkManager.shared
            let server = try BootstrapSocketConnectionManager(
                connectionID: id, sessionToken: token, clientPid: Int(getpid()), observedKernelPeerPID: Int(peerPID),
                clientName: name, purpose: purpose, codeMapsDisabled: true, connectedFD: descriptors[0], parentManager: network
            )
            descriptors[0] = -1
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[1], connectionID: id, correlationConnectionID: token)
            descriptors[1] = -1
            await network.debugInstallDirectAdmissionConnectionForTesting(connectionID: id, connection: server, pendingClientID: name)
            _ = await network.debugInstallConnectionLimiterForTesting(connectionID: id)
            let connection = RoutedConnection(client: Client(name: name, version: "1.0"), connectionID: id, server: server)
            connections.append(connection)
            do {
                try await server.start { info in
                    guard info.name == name else { return false }
                    // Match ServerController's real pre-approval capacity admission. Only the
                    // user approval answer is substituted; admission/index ownership is not.
                    guard await network.tryReserveConnectionSlot(connectionID: id, clientID: info.name) else { return false }
                    return await network.debugCompleteApprovedAgentInitialization(
                        clientName: name, connectionID: id, sessionToken: token, clientPid: Int(getpid())
                    )
                }
                _ = try await connection.client.connect(transport: transport)
                return connection
            } catch {
                await transport.disconnect()
                await connection.cleanup()
                throw error
            }
        }

        func promotedSnapshot(for connection: RoutedConnection) throws -> MCPServerViewModel.TabContextSnapshot {
            try window.mcpServer.resolveTabContextSnapshot(
                from: .init(connectionID: connection.connectionID, clientName: nil, windowID: window.windowID),
                toolName: "read_file", startMirroring: false
            ).snapshot
        }

        func discover(using connection: RoutedConnection) async throws {
            // The unrelated directory is genuinely loaded, not just an out-of-workspace missing path.
            try await files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[2]), for: fixture.workspace)
            let loadedRoots = await files.workspaceFileContextStore.roots()
            XCTAssertTrue(loadedRoots.contains { $0.standardizedFullPath == fixture.rootPaths[2] })
            for path in fixture.rootPaths.prefix(2) {
                let reply = try await connection.client.callTool(name: "read_file", arguments: ["path": .string(path + "/README.md")])
                XCTAssertNotEqual(reply.isError, true, Self.text(reply))
                XCTAssertTrue(Self.text(reply).contains("fixture"))
            }
            do {
                let reply = try await connection.client.callTool(name: "read_file", arguments: ["path": .string(fixture.rootPaths[2] + "/README.md")])
                XCTAssertEqual(reply.isError, true, "Unrelated root was readable")
            } catch is MCPError { /* Actual dispatcher may reject as a JSON-RPC error. */ }
            // Finish this auxiliary read-isolation control before validating the configured
            // primary manifest at commit. A/B themselves retain their original identities.
            await files.unloadRootFolderPath(fixture.rootPaths[2])
            let selected = try await connection.client.callTool(name: "manage_selection", arguments: [
                "op": .string("set"), "paths": .array(fixture.rootPaths.prefix(2).map { .string($0 + "/README.md") }), "mode": .string("full")
            ])
            XCTAssertNotEqual(selected.isError, true, Self.text(selected))
            let prompt = try await connection.client.callTool(name: "prompt", arguments: ["op": .string("set"), "text": .string("ROUTED_DISCOVERY_RESULT")])
            XCTAssertNotEqual(prompt.isError, true, Self.text(prompt))
        }

        static func text(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { if case let .text(text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
        }

        final class RoutedConnection {
            let client: Client
            let connectionID: UUID
            let server: BootstrapSocketConnectionManager
            var cleanupCount = 0
            init(client: Client, connectionID: UUID, server: BootstrapSocketConnectionManager) {
                self.client = client
                self.connectionID = connectionID
                self.server = server
            }

            func cleanup() async {
                guard cleanupCount == 0 else { return }
                cleanupCount += 1
                await client.disconnect()
                await server.stop()
                let network = ServerNetworkManager.shared
                await network.debugRemoveConnection(connectionID)
                let state = await network.debugDirectAdmissionStateForTesting(connectionID: connectionID)
                XCTAssertNil(state.pendingClientID)
                XCTAssertNil(state.indexedClientID)
                XCTAssertTrue(state.activeClientIDs.isEmpty)
                XCTAssertFalse(state.hasStats)
                XCTAssertNil(state.connectionLifecycleGeneration)
                let history = await network.debugConnectionHistoryPayload(
                    limit: 200, clientName: nil, sessionFingerprint: nil, connectionID: connectionID
                )
                let events = history["events"] as? [[String: Any]] ?? []
                XCTAssertEqual(events.count(where: { $0["event"] as? String == "removed" }), 1)
            }
        }

        func assertReleased(runID: UUID) async throws {
            try await fixture.awaitGateEvent(teardown)
            XCTAssertEqual(teardownIDs, [runID])
            XCTAssertEqual(runSettlementCount, 1)
            XCTAssertNil(vm.activeRunIDForTesting(tabID: tabID))
            XCTAssertFalse(vm.isRunTeardownPendingForTesting(runID: runID))
            let token = try vm.beginMCPControlledRun(forTabID: tabID, responseType: nil, planModelName: nil)
            vm.clearMCPControlledRun(forTabID: tabID, controlToken: token)
            let pending = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: AgentProviderKind.claudeCode.mcpClientNameHint!)
            XCTAssertFalse(pending.contains { $0.runID == runID })
            let routingWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(routingWaiters, 0)
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertNotEqual(activeGate, runID)
        }

        func assertRoutedLeaseReleasedExactlyOnce(runID: UUID) async throws {
            let payload = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: runID, limit: 200)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            let releases = events.filter { $0["event"] as? String == "lease_gate_release" }
            XCTAssertEqual(releases.count, 1)
            XCTAssertEqual((releases.first?["fields"] as? [String: String])?["released"], "true")
            let routes = events.filter { $0["event"] as? String == "route_wait_completed" }
            XCTAssertEqual(routes.count, 1)
            XCTAssertEqual((routes.first?["fields"] as? [String: String])?["outcome"], "routed")
        }

        func assertLeaseFailedExactlyOnce(runID: UUID) async throws {
            let payload = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: runID, limit: 200)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.count(where: { $0["event"] as? String == "lease_cancelled" }), 1)
            let cleanup = events.filter { $0["event"] as? String == "lease_cleanup_completed" }
            XCTAssertEqual(cleanup.count, 1)
            let fields = try XCTUnwrap(cleanup.first?["fields"] as? [String: String])
            XCTAssertEqual(fields["owns_gate"], "false")
            XCTAssertEqual(fields["gate_released"], "true")
            XCTAssertEqual(fields["routing_cleaned"], "true")
            XCTAssertEqual(fields["policy_cleared"], "true")
        }

        private func shutdown() async {
            fixture.releaseAllGates()
            if let window {
                let needsTeardownJoin = vm.activeRunIDForTesting(tabID: tabID) != nil || constructed > 0
                manager.rootReconciliationGateForTesting = nil
                manager.rootReconciliationWaiterCountDidChangeForTesting = nil
                manager.rootProbeFailureForTesting = nil
                await vm.cancelAllActiveRuns()
                await fixture.joinOwnedTasks()
                providerValidationBody = nil
                providerValidationError = nil
                afterCommittedTabSnapshotCaptured = nil
                streamBody = nil
                if needsTeardownJoin, teardownIDs.isEmpty {
                    await withCheckedContinuation { teardownWaiters.append($0) }
                }
                for parent in parentRuns {
                    await parent.lease.cancelAndCleanup()
                    window.mcpServer.removeTabContext(forConnectionID: nil, clientName: parent.clientName, windowID: window.windowID, runID: parent.runID)
                }
                for connection in connections {
                    await connection.cleanup()
                }
                vm.clearStartupObservationForTesting()
                for sessionID in bindingSessionIDs {
                    await WorkspaceRootBindingProjectionMaterializer(store: files.workspaceFileContextStore).release(sessionID: sessionID)
                }
                await window.joinDomainWorkspaceBridgeForTesting()
                await window.tearDown()
                await manager.debugDrainScheduledSaves()
                for workspace in manager.workspaces {
                    await manager.debugAwaitWorkingDocumentCommitToDomainAuthority(workspaceID: workspace.id)
                }
                for root in await files.workspaceFileContextStore.roots() {
                    await files.unloadRootFolderPath(root.standardizedFullPath)
                }
                vm.installRunTestHooks(nil)
                WindowStatesManager.shared.allWindows = previousWindows
            }
            await polling.shutdown()
            if !networkWasRunning { await ServerNetworkManager.shared.stop() }
        }

        @MainActor
        private final class Provider: HeadlessAgentProvider {
            unowned let driver: ContextBuilderMultiRootDiscoveryDriver
            init(driver: ContextBuilderMultiRootDiscoveryDriver) {
                self.driver = driver
            }

            func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
                driver.streamStarts += 1
                let id = try XCTUnwrap(runID)
                if let body = driver.streamBody { try await body(id) }
                else { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected stream start"]) }
                return AsyncThrowingStream { $0.finish() }
            }

            func dispose() async {
                driver.disposed += 1
            }
        }

        private actor EmptyModelClient: CodexModelListingClient {
            func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
                []
            }

            func stop() async {}
        }
    }
#endif
