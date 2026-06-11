import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PersistentAgentModeMCPReadFileConnectionTests: XCTestCase {
    func testCodexAgentModeLeaseRetainsOneMCPServerSessionAcrossSerialExactAbsoluteReadFileCalls() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .serialReads)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedReadRepliesReturnBeforeWorkspaceContextDrainSettlesAutoSelection() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .workspaceContextDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedPromptExportWaitsForPendingReadSelectionDrain() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .promptExportDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedManageSelectionClearDrainsPendingReadAdditionBeforeApplyingClear() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .manageSelectionClear)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedEndOfRunCleanupWaitsForAcceptedReadSelectionAndCommitsFinalState() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .endOfRun)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }

    func testRetainedEligibleContentSearchReplyReturnsBeforeWorkspaceContextDrainSettlesAutoSelection() async throws {
        #if DEBUG
            try await withFixture { fixture in
                try await runCheckpoint(fixture: fixture, scenario: .searchWorkspaceContextDrain)
            }
        #else
            throw XCTSkip("Persistent Agent Mode MCP socketpair integration requires DEBUG inspection helpers.")
        #endif
    }
}

#if DEBUG
    private extension PersistentAgentModeMCPReadFileConnectionTests {
        enum CheckpointScenario {
            case serialReads
            case workspaceContextDrain
            case promptExportDrain
            case manageSelectionClear
            case endOfRun
            case searchWorkspaceContextDrain
        }

        func withFixture(_ operation: (Fixture) async throws -> Void) async throws {
            let fixture = try await Fixture.make()
            do {
                try await operation(fixture)
                await fixture.cleanup()
                let pendingAfterCleanup = await fixture.networkManager.debugPendingPolicySnapshot(
                    for: AgentProviderKind.codexMCPClientID
                )
                XCTAssertFalse(pendingAfterCleanup.contains { $0.runID == Fixture.runID })
                let runPolicyAfterCleanup = await fixture.networkManager.debugRunPolicyState(for: Fixture.runID)
                XCTAssertNil(runPolicyAfterCleanup)
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        /// Dynamically proves one real retained BootstrapSocketConnectionManager/MCP.Server
        /// initialization and ordinary wire-level CallTool dispatch over one connected FD.
        /// The direct socketpair manager is intentionally not inserted into the parent's private
        /// dashboard registry, so registry history and registry-derived fingerprint claims remain
        /// outside this checkpoint's proof boundary.
        func runCheckpoint(fixture: Fixture, scenario: CheckpointScenario) async throws {
            let spec = fixture.spec
            XCTAssertEqual(spec.clientName, AgentProviderKind.codexMCPClientID)
            XCTAssertEqual(spec.purpose, .agentModeRun)
            XCTAssertTrue(spec.oneShot)
            XCTAssertTrue(spec.requiresExpectedAgentPID)
            XCTAssertEqual(spec.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(spec.additionalTools, AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec))

            let pendingBeforeInitialize = await fixture.networkManager.debugPendingPolicySnapshot(
                for: AgentProviderKind.codexMCPClientID
            )
            XCTAssertEqual(pendingBeforeInitialize.count, 1)
            XCTAssertEqual(pendingBeforeInitialize.first?.windowID, fixture.windowID)
            XCTAssertEqual(pendingBeforeInitialize.first?.tabID, Fixture.tabID)
            XCTAssertEqual(pendingBeforeInitialize.first?.runID, Fixture.runID)
            XCTAssertEqual(pendingBeforeInitialize.first?.oneShot, true)
            XCTAssertEqual(pendingBeforeInitialize.first?.purpose, .agentModeRun)

            let manager = fixture.connectionManager
            let recorder = fixture.handshakeRecorder
            let networkManager = fixture.networkManager
            let startTask = Task {
                try await manager.start { clientInfo in
                    await recorder.recordInitialize(clientName: clientInfo.name)
                    let admission = await networkManager.debugAgentPolicyAdmissionStatus(
                        clientName: AgentProviderKind.codexMCPClientID,
                        bootstrapClientName: AgentProviderKind.codexMCPClientID,
                        connectionID: Fixture.connectionID,
                        sessionKey: Fixture.sessionToken,
                        clientPid: Int(getpid())
                    )
                    await recorder.recordAdmission(admission)
                    guard admission == "ready" else { return false }

                    let applied = await networkManager.debugApplyPendingPolicy(
                        clientName: AgentProviderKind.codexMCPClientID,
                        connectionID: Fixture.connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: AgentProviderKind.codexMCPClientID
                    )
                    await recorder.recordPolicyApplication(
                        restrictedTools: applied.restrictedTools,
                        additionalTools: applied.additionalTools,
                        purpose: applied.purpose,
                        windowID: applied.windowID
                    )
                    return true
                }
            }

            do {
                let initializeResponse = try await fixture.socketClient.request(
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": AgentProviderKind.codexMCPClientID,
                            "version": "persistent-agent-mode-read-file-checkpoint"
                        ]
                    ]
                )
                try Self.assertSuccessfulResponse(initializeResponse, id: 1)
                try await startTask.value
            } catch {
                startTask.cancel()
                await manager.stop()
                _ = try? await startTask.value
                throw error
            }

            try fixture.socketClient.sendNotification(
                method: "notifications/initialized",
                params: [:]
            )
            let toolsResponse = try await fixture.socketClient.request(
                id: 2,
                method: "tools/list",
                params: [:]
            )
            XCTAssertTrue(try Self.toolNames(from: toolsResponse).contains(MCPWindowToolName.readFile))

            let routed = await fixture.lease.releaseWhenRouted(timeoutMs: 1000)
            XCTAssertTrue(routed)

            let baseline = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(baseline, fixture: fixture)

            var firstFormattedRead: String?
            for requestID in 3 ... 5 {
                let response = try await fixture.socketClient.request(
                    id: requestID,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.readFile,
                        "arguments": ["path": fixture.fileURL.path]
                    ]
                )
                let formattedRead = try Self.readFileText(from: response, id: requestID)
                XCTAssertTrue(formattedRead.contains(Fixture.sentinelContent), formattedRead)
                if let firstFormattedRead {
                    XCTAssertEqual(formattedRead, firstFormattedRead)
                } else {
                    firstFormattedRead = formattedRead
                }

                let current = await fixture.retainedConnectionSnapshot()
                XCTAssertEqual(current, baseline)
                Self.assertStableAgentModeSnapshot(current, fixture: fixture)
            }

            switch scenario {
            case .serialReads:
                break
            case .workspaceContextDrain:
                try await assertWorkspaceContextDrain(fixture: fixture)
            case .promptExportDrain:
                try await assertPromptExportDrain(fixture: fixture)
            case .manageSelectionClear:
                try await assertManageSelectionClearOrdering(fixture: fixture)
            case .endOfRun:
                try await assertEndOfRunFinish(fixture: fixture)
            case .searchWorkspaceContextDrain:
                try await assertSearchWorkspaceContextDrain(fixture: fixture)
            }
        }

        func assertWorkspaceContextDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let firstRead = gatedReadTask(fixture: fixture, id: 6)
            await gate.waitUntilStarted()
            try await assertReadReplyReturned(firstRead, gate: gate, id: 6)
            let secondRead = gatedReadTask(fixture: fixture, id: 7)
            try await assertReadReplyReturned(secondRead, gate: gate, id: 7)

            let contextFinished = PersistentAsyncSignal()
            let contextTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 8,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.workspaceContext,
                        "arguments": [:]
                    ]
                )
                await contextFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let contextReturnedBeforeDrain = await contextFinished.isMarked()
            XCTAssertFalse(contextReturnedBeforeDrain)

            await gate.release()
            let contextResponse = try await contextTask.value
            try Self.assertSuccessfulResponse(contextResponse, id: 8)
            XCTAssertTrue(contextResponse.contains("PersistentAgentModeFixture.swift"), contextResponse)
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertPromptExportDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 6)
            await gate.waitUntilStarted()
            try await assertReadReplyReturned(read, gate: gate, id: 6)

            let exportURL = fixture.rootURL.appendingPathComponent("prompt-export.txt")
            let exportFinished = PersistentAsyncSignal()
            let exportTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 7,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.prompt,
                        "arguments": [
                            "op": "export",
                            "path": exportURL.path
                        ]
                    ]
                )
                await exportFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let exportReturnedBeforeDrain = await exportFinished.isMarked()
            XCTAssertFalse(exportReturnedBeforeDrain)

            await gate.release()
            try await Self.assertSuccessfulResponse(exportTask.value, id: 7)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
            let exported = try String(contentsOf: exportURL, encoding: .utf8)
            XCTAssertTrue(exported.contains("PersistentAgentModeFixture.swift"), exported)
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertManageSelectionClearOrdering(fixture: Fixture) async throws {
            let initialClear = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "clear"]
                ]
            )
            try Self.assertSuccessfulResponse(initialClear, id: 6)

            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            await gate.waitUntilStarted()
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let clearFinished = PersistentAsyncSignal()
            let clearTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 8,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.manageSelection,
                        "arguments": ["op": "clear"]
                    ]
                )
                await clearFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let clearReturnedBeforeDrain = await clearFinished.isMarked()
            XCTAssertFalse(clearReturnedBeforeDrain)

            await gate.release()
            try await Self.assertSuccessfulResponse(clearTask.value, id: 8)
            let finalSelection = fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID]?.selection
            XCTAssertEqual(finalSelection?.selectedPaths, [])
            XCTAssertEqual(finalSelection?.slices, [:])
            let current = await fixture.retainedConnectionSnapshot()
            Self.assertStableAgentModeSnapshot(current, fixture: fixture)
        }

        func assertEndOfRunFinish(fixture: Fixture) async throws {
            let initialClear = try await fixture.socketClient.request(
                id: 6,
                method: "tools/call",
                params: [
                    "name": MCPWindowToolName.manageSelection,
                    "arguments": ["op": "clear"]
                ]
            )
            try Self.assertSuccessfulResponse(initialClear, id: 6)

            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let read = gatedReadTask(fixture: fixture, id: 7)
            await gate.waitUntilStarted()
            try await assertReadReplyReturned(read, gate: gate, id: 7)

            let finishCompleted = PersistentAsyncSignal()
            let finishTask = Task { @MainActor in
                await fixture.window.mcpServer.commitAndClearTabContext(
                    connectionID: Fixture.connectionID,
                    expectedRunID: Fixture.runID
                )
                await finishCompleted.mark()
            }
            try await Task.sleep(for: .milliseconds(50))
            let finishedBeforeRelease = await finishCompleted.isMarked()
            XCTAssertFalse(finishedBeforeRelease)

            await gate.release()
            await finishTask.value
            let storedSelection = fixture.window.workspaceManager.composeTab(with: Fixture.tabID)?.selection
            XCTAssertEqual(storedSelection?.selectedPaths, [fixture.fileURL.path])
            XCTAssertNil(fixture.window.mcpServer.tabContextByConnectionID[Fixture.connectionID])
        }

        func assertSearchWorkspaceContextDrain(fixture: Fixture) async throws {
            let gate = PersistentAsyncGate()
            fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                fixture.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                Task { await gate.release() }
            }

            let searchTask = Task {
                try await fixture.socketClient.request(
                    id: 6,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.search,
                        "arguments": [
                            "pattern": "persistentAgentModeCheckpoint",
                            "mode": "content",
                            "regex": false,
                            "context_lines": 2
                        ]
                    ]
                )
            }
            await gate.waitUntilStarted()
            let searchFinished = PersistentAsyncSignal()
            let searchObserver = Task {
                let result = await searchTask.result
                await searchFinished.mark()
                return result
            }
            let replyReturnedBeforeCanonicalApply = await waitUntilMarked(searchFinished, timeout: .seconds(2))
            XCTAssertTrue(replyReturnedBeforeCanonicalApply)
            if !replyReturnedBeforeCanonicalApply {
                await gate.release()
            }
            let response = try await searchObserver.value.get()
            try Self.assertSuccessfulResponse(response, id: 6)
            XCTAssertTrue(response.contains("PersistentAgentModeFixture.swift"), response)

            let contextFinished = PersistentAsyncSignal()
            let contextTask = Task {
                let response = try await fixture.socketClient.request(
                    id: 7,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.workspaceContext,
                        "arguments": [:]
                    ]
                )
                await contextFinished.mark()
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
            let contextReturnedBeforeDrain = await contextFinished.isMarked()
            XCTAssertFalse(contextReturnedBeforeDrain)

            await gate.release()
            let contextResponse = try await contextTask.value
            try Self.assertSuccessfulResponse(contextResponse, id: 7)
            XCTAssertTrue(contextResponse.contains("PersistentAgentModeFixture.swift"), contextResponse)
        }

        func gatedReadTask(fixture: Fixture, id: Int) -> Task<String, Error> {
            Task {
                try await fixture.socketClient.request(
                    id: id,
                    method: "tools/call",
                    params: [
                        "name": MCPWindowToolName.readFile,
                        "arguments": ["path": fixture.fileURL.path]
                    ]
                )
            }
        }

        func assertReadReplyReturned(_ task: Task<String, Error>, gate: PersistentAsyncGate, id: Int) async throws {
            let finished = PersistentAsyncSignal()
            let observer = Task {
                let result = await task.result
                await finished.mark()
                return result
            }
            let replyReturnedBeforeCanonicalApply = await waitUntilMarked(finished, timeout: .seconds(2))
            XCTAssertTrue(replyReturnedBeforeCanonicalApply)
            if !replyReturnedBeforeCanonicalApply {
                await gate.release()
            }
            let response = try await observer.value.get()
            let formattedRead = try Self.readFileText(from: response, id: id)
            XCTAssertTrue(formattedRead.contains(Fixture.sentinelContent), formattedRead)
        }

        func waitUntilMarked(_ signal: PersistentAsyncSignal, timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await signal.isMarked() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await signal.isMarked()
        }

        static func assertStableAgentModeSnapshot(_ snapshot: RetainedConnectionSnapshot, fixture: Fixture) {
            XCTAssertEqual(snapshot.connectionID, Fixture.connectionID)
            XCTAssertEqual(snapshot.capabilityToken, Fixture.sessionToken)
            XCTAssertEqual(snapshot.managerState, .ready)
            XCTAssertTrue(snapshot.managerViable)
            XCTAssertEqual(snapshot.peerPID, Int(getpid()))
            XCTAssertEqual(snapshot.runPurpose, .agentModeRun)
            XCTAssertEqual(snapshot.runID, Fixture.runID)
            XCTAssertEqual(snapshot.connectionPolicy.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.connectionPolicy.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.connectionPolicy.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.connectionPolicy.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.runPolicy?.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.runPolicy?.workspaceID, fixture.workspaceID)
            XCTAssertEqual(snapshot.runPolicy?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.runPolicy?.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.runPolicy?.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.pendingPolicyCount, 0)
            XCTAssertEqual(snapshot.binding.bindingKind, .tabContext)
            XCTAssertEqual(snapshot.binding.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.binding.tabID, Fixture.tabID)
            XCTAssertEqual(snapshot.binding.workspaceID, fixture.workspaceID)
            XCTAssertEqual(snapshot.binding.repoPaths, [fixture.rootURL.path])
            XCTAssertEqual(snapshot.binding.runID, Fixture.runID)
            XCTAssertEqual(snapshot.mappedConnectionID, Fixture.connectionID)
            XCTAssertEqual(snapshot.handshake.initializeCount, 1)
            XCTAssertEqual(snapshot.handshake.clientName, AgentProviderKind.codexMCPClientID)
            XCTAssertEqual(snapshot.handshake.admissionStatus, "ready")
            XCTAssertEqual(snapshot.handshake.policyApplicationCount, 1)
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
            XCTAssertEqual(
                snapshot.handshake.appliedPolicy?.additionalTools,
                AgentModeMCPPolicyInstaller.additionalTools(for: .codexExec)
            )
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.purpose, .agentModeRun)
            XCTAssertEqual(snapshot.handshake.appliedPolicy?.windowID, fixture.windowID)
            XCTAssertEqual(snapshot.limiter?.limit, 1)
            XCTAssertEqual(snapshot.limiter?.permits, 1)
            XCTAssertEqual(snapshot.limiter?.activePermitCount, 0)
            XCTAssertEqual(snapshot.limiter?.waiterCount, 0)
            XCTAssertEqual(snapshot.limiter?.inFlight, 0)
            XCTAssertEqual(snapshot.limiter?.cancelledWaiterCount, 0)
            XCTAssertEqual(snapshot.limiter?.isClosed, false)
            XCTAssertEqual(snapshot.limiter?.isIdle, true)
        }

        static func assertSuccessfulResponse(_ rawJSON: String, id: Int) throws {
            let object = try responseObject(from: rawJSON, id: id)
            XCTAssertNil(object["error"])
        }

        static func toolNames(from rawJSON: String) throws -> [String] {
            let object = try responseObject(from: rawJSON, id: 2)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }

        static func readFileText(from rawJSON: String, id: Int) throws -> String {
            let object = try responseObject(from: rawJSON, id: id)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            XCTAssertNotEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        static func responseObject(from rawJSON: String, id: Int) throws -> [String: Any] {
            let data = try XCTUnwrap(rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, id)
            XCTAssertNil(object["error"])
            return object
        }
    }

    @MainActor
    private final class Fixture {
        static let runID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let tabID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let gateID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let connectionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        static let sessionToken = "persistent-agent-mode-read-file-checkpoint-session"
        static let sentinelContent = "let persistentAgentModeCheckpoint = \"retained-session-read\"\n"

        let networkManager = ServerNetworkManager.shared
        let rootURL: URL
        let fileURL: URL
        let rootID: UUID
        let window: WindowState
        let routingGuardWindow: WindowState
        let windowID: Int
        let workspaceID: UUID
        let catalogService: MCPWindowToolCatalogService
        let socketClient: SocketPairJSONRPCClient
        let connectionManager: BootstrapSocketConnectionManager
        let handshakeRecorder = HandshakeRecorder()
        let spec: MCPBootstrapLeaseSpec
        let lease: MCPBootstrapLease
        private var cleanedUp = false

        private init(
            rootURL: URL,
            fileURL: URL,
            rootID: UUID,
            window: WindowState,
            routingGuardWindow: WindowState,
            workspaceID: UUID,
            catalogService: MCPWindowToolCatalogService,
            socketClient: SocketPairJSONRPCClient,
            connectionManager: BootstrapSocketConnectionManager,
            spec: MCPBootstrapLeaseSpec,
            lease: MCPBootstrapLease
        ) {
            self.rootURL = rootURL
            self.fileURL = fileURL
            self.rootID = rootID
            self.window = window
            self.routingGuardWindow = routingGuardWindow
            windowID = window.windowID
            self.workspaceID = workspaceID
            self.catalogService = catalogService
            self.socketClient = socketClient
            self.connectionManager = connectionManager
            self.spec = spec
            self.lease = lease
        }

        static func make() async throws -> Fixture {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = rootURL.appendingPathComponent("Sources/PersistentAgentModeFixture.swift")
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try sentinelContent.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            let routingGuardWindow = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            // Keep dispatch in ordinary multi-window routing mode so catalog services retained by
            // earlier tests are filtered by window ID instead of relying on singleton cleanliness.
            WindowStatesManager.shared.registerWindowState(routingGuardWindow)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            var rootID: UUID?
            var catalogService: MCPWindowToolCatalogService?
            var socketClient: SocketPairJSONRPCClient?
            var connectionManager: BootstrapSocketConnectionManager?
            var lease: MCPBootstrapLease?

            do {
                let workspace = window.workspaceManager.createWorkspace(
                    name: "Persistent Agent Mode MCP Read",
                    repoPaths: [rootURL.path],
                    ephemeral: true
                )
                let workspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                    ComposeTabState(id: tabID, name: "Persistent Agent Mode MCP Read")
                ]
                window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
                let configuredWorkspace = window.workspaceManager.workspaces[workspaceIndex]
                await window.workspaceManager.switchWorkspace(
                    to: configuredWorkspace,
                    saveState: false,
                    reason: "persistentAgentModeMCPReadFileConnectionTest"
                )
                let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
                let rootRecord = try await window.workspaceFileContextStore.loadRoot(path: rootURL.path)
                rootID = rootRecord.id
                let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                    .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
                guard exactHit?.standardizedFullPath == fileURL.path else {
                    throw ClientFixtureError.exactAbsoluteCatalogMiss
                }

                let resolvedCatalogService = window.mcpServer.windowMCPToolCatalogService
                catalogService = resolvedCatalogService
                ServiceRegistry.register(resolvedCatalogService)

                var socketFDs = [Int32](repeating: -1, count: 2)
                guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                    throw SocketPairJSONRPCClient.ClientError.posix(operation: "socketpair", code: errno)
                }
                var noSigPipe: Int32 = 1
                guard Darwin.setsockopt(
                    socketFDs[0],
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout.size(ofValue: noSigPipe))
                ) == 0 else {
                    let code = errno
                    Darwin.close(socketFDs[0])
                    Darwin.close(socketFDs[1])
                    throw SocketPairJSONRPCClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
                }
                let resolvedSocketClient = SocketPairJSONRPCClient(fd: socketFDs[0])
                socketClient = resolvedSocketClient
                let resolvedConnectionManager = try BootstrapSocketConnectionManager(
                    connectionID: connectionID,
                    sessionToken: sessionToken,
                    clientPid: Int(getpid()),
                    clientName: AgentProviderKind.codexMCPClientID,
                    purpose: .agentModeRun,
                    codeMapsDisabled: false,
                    connectedFD: socketFDs[1],
                    parentManager: ServerNetworkManager.shared
                )
                connectionManager = resolvedConnectionManager
                await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: resolvedConnectionManager,
                    clientName: AgentProviderKind.codexMCPClientID,
                    sessionToken: sessionToken
                )
                let spec = MCPBootstrapLeaseSpec.agentMode(
                    tabID: tabID,
                    runID: runID,
                    gateID: gateID,
                    windowID: window.windowID,
                    agent: .codexExec
                )
                let resolvedLease = MCPBootstrapLease(spec: spec)
                lease = resolvedLease
                guard await resolvedLease.acquire() else {
                    throw ClientFixtureError.leaseAcquisitionFailed
                }
                await ServerNetworkManager.shared.registerExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.codexMCPClientID,
                    runID: runID
                )

                return Fixture(
                    rootURL: rootURL,
                    fileURL: fileURL,
                    rootID: rootRecord.id,
                    window: window,
                    routingGuardWindow: routingGuardWindow,
                    workspaceID: activeWorkspace.id,
                    catalogService: resolvedCatalogService,
                    socketClient: resolvedSocketClient,
                    connectionManager: resolvedConnectionManager,
                    spec: spec,
                    lease: resolvedLease
                )
            } catch {
                await connectionManager?.stop()
                socketClient?.close()
                await ServerNetworkManager.shared.removeConnection(connectionID)
                await ServerNetworkManager.shared.clearExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.codexMCPClientID,
                    runID: runID
                )
                await ServerNetworkManager.shared.clearClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await lease?.cancelAndCleanup()
                window.mcpServer.removeTabContext(
                    forConnectionID: connectionID,
                    clientName: AgentProviderKind.codexMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                if let catalogService {
                    ServiceRegistry.unregister(catalogService)
                }
                if let rootID {
                    await window.workspaceFileContextStore.unloadRoot(id: rootID)
                }
                WindowStatesManager.shared.unregisterWindowState(routingGuardWindow)
                WindowStatesManager.shared.unregisterWindowState(window)
                try? FileManager.default.removeItem(at: rootURL)
                throw error
            }
        }

        func retainedConnectionSnapshot() async -> RetainedConnectionSnapshot {
            let connectionPolicy = await networkManager.debugConnectionPolicyState(for: Self.connectionID)
            let runPolicy = await networkManager.debugRunPolicyState(for: Self.runID)
            let pendingPolicyCount = await networkManager.debugPendingPolicySnapshot(
                for: AgentProviderKind.codexMCPClientID
            ).count
            let limiter = await networkManager.connectionLimiterSnapshotForTesting(
                connectionID: Self.connectionID
            )
            return await RetainedConnectionSnapshot(
                connectionID: Self.connectionID,
                capabilityToken: connectionManager.capabilityToken,
                managerState: connectionManager.connectionState(),
                managerViable: connectionManager.isViableForRetention(),
                peerPID: connectionManager.peerPID(),
                runPurpose: networkManager.runPurpose(for: Self.connectionID),
                runID: networkManager.runIDForConnection(Self.connectionID),
                connectionPolicy: ConnectionPolicySnapshot(
                    restrictedTools: connectionPolicy.restrictedTools,
                    additionalTools: connectionPolicy.additionalTools,
                    purpose: connectionPolicy.purpose,
                    windowID: connectionPolicy.windowID
                ),
                runPolicy: runPolicy.map {
                    RunPolicySnapshot(
                        windowID: $0.windowID,
                        workspaceID: $0.workspaceID,
                        restrictedTools: $0.restrictedTools,
                        additionalTools: $0.additionalTools,
                        purpose: $0.purpose
                    )
                },
                pendingPolicyCount: pendingPolicyCount,
                binding: window.mcpServer.connectionBindingSnapshot(forConnection: Self.connectionID),
                mappedConnectionID: window.mcpServer.connectionID(forRunID: Self.runID),
                handshake: handshakeRecorder.snapshot(),
                limiter: limiter
            )
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true

            await connectionManager.stop()
            socketClient.close()
            await networkManager.removeConnection(Self.connectionID)
            let limiterAfterRemoval = await networkManager.connectionLimiterSnapshotForTesting(
                connectionID: Self.connectionID
            )
            XCTAssertNil(limiterAfterRemoval)
            await networkManager.clearExpectedAgentPID(
                getpid(),
                for: AgentProviderKind.codexMCPClientID,
                runID: Self.runID
            )
            await networkManager.clearClientConnectionPolicy(
                for: AgentProviderKind.codexMCPClientID,
                windowID: windowID,
                runID: Self.runID
            )
            await networkManager.cleanupRunRoutingState(for: Self.runID, windowID: windowID)
            await lease.cancelAndCleanup()
            window.mcpServer.removeTabContext(
                forConnectionID: Self.connectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                windowID: windowID,
                runID: Self.runID
            )
            ServiceRegistry.unregister(catalogService)
            await window.workspaceFileContextStore.unloadRoot(id: rootID)
            WindowStatesManager.shared.unregisterWindowState(routingGuardWindow)
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private enum ClientFixtureError: Error {
        case exactAbsoluteCatalogMiss
        case leaseAcquisitionFailed
    }

    private struct RetainedConnectionSnapshot: Equatable {
        let connectionID: UUID
        let capabilityToken: String?
        let managerState: ConnectionStateSnapshot
        let managerViable: Bool
        let peerPID: Int
        let runPurpose: MCPRunPurpose
        let runID: UUID?
        let connectionPolicy: ConnectionPolicySnapshot
        let runPolicy: RunPolicySnapshot?
        let pendingPolicyCount: Int
        let binding: MCPServerViewModel.ConnectionBindingSnapshot
        let mappedConnectionID: UUID?
        let handshake: HandshakeRecorder.Snapshot
        let limiter: AsyncLimiter.DebugSnapshot?
    }

    private struct ConnectionPolicySnapshot: Equatable {
        let restrictedTools: Set<String>
        let additionalTools: Set<String>
        let purpose: MCPRunPurpose
        let windowID: Int?
    }

    private struct RunPolicySnapshot: Equatable {
        let windowID: Int
        let workspaceID: UUID?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>?
        let purpose: MCPRunPurpose
    }

    private actor HandshakeRecorder {
        struct AppliedPolicy: Equatable {
            let restrictedTools: Set<String>
            let additionalTools: Set<String>
            let purpose: MCPRunPurpose
            let windowID: Int?
        }

        struct Snapshot: Equatable {
            let initializeCount: Int
            let clientName: String?
            let admissionStatus: String?
            let policyApplicationCount: Int
            let appliedPolicy: AppliedPolicy?
        }

        private var initializeCount = 0
        private var clientName: String?
        private var admissionStatus: String?
        private var policyApplicationCount = 0
        private var appliedPolicy: AppliedPolicy?

        func recordInitialize(clientName: String) {
            initializeCount += 1
            self.clientName = clientName
        }

        func recordAdmission(_ status: String) {
            admissionStatus = status
        }

        func recordPolicyApplication(
            restrictedTools: Set<String>,
            additionalTools: Set<String>,
            purpose: MCPRunPurpose,
            windowID: Int?
        ) {
            policyApplicationCount += 1
            appliedPolicy = AppliedPolicy(
                restrictedTools: restrictedTools,
                additionalTools: additionalTools,
                purpose: purpose,
                windowID: windowID
            )
        }

        func snapshot() -> Snapshot {
            Snapshot(
                initializeCount: initializeCount,
                clientName: clientName,
                admissionStatus: admissionStatus,
                policyApplicationCount: policyApplicationCount,
                appliedPolicy: appliedPolicy
            )
        }
    }

    private actor PersistentAsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor PersistentAsyncSignal {
        private var marked = false

        func mark() {
            marked = true
        }

        func isMarked() -> Bool {
            marked
        }
    }

    private final class SocketPairJSONRPCClient: @unchecked Sendable {
        enum ClientError: Error {
            case closed
            case invalidResponse
            case posix(operation: String, code: Int32)
            case timedOut
        }

        private let queue = DispatchQueue(label: "PersistentAgentModeMCPReadFileConnectionTests.socket")
        private var fd: Int32
        private var buffer = Data()
        private var nonMatchingFrames: [String] = []

        init(fd: Int32) {
            self.fd = fd
        }

        deinit {
            close()
        }

        func close() {
            queue.sync {
                guard fd >= 0 else { return }
                Darwin.close(fd)
                fd = -1
            }
        }

        func sendNotification(method: String, params: [String: Any]) throws {
            try sendJSON([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        }

        func request(id: Int, method: String, params: [String: Any]) async throws -> String {
            try sendJSON([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
            return try await response(matching: id)
        }

        private func sendJSON(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            try queue.sync {
                try writeAll(line)
            }
        }

        private func response(matching expectedID: Int) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        while true {
                            let line = try self.readLine()
                            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                            guard let object else { throw ClientError.invalidResponse }
                            if let rawID = object["id"] {
                                guard let responseID = (rawID as? NSNumber)?.intValue else {
                                    throw ClientError.invalidResponse
                                }
                                guard responseID == expectedID else {
                                    throw ClientError.invalidResponse
                                }
                                guard let rawJSON = String(data: line, encoding: .utf8) else {
                                    throw ClientError.invalidResponse
                                }
                                continuation.resume(returning: rawJSON)
                                return
                            }
                            guard object["method"] as? String != nil,
                                  let rawJSON = String(data: line, encoding: .utf8)
                            else {
                                throw ClientError.invalidResponse
                            }
                            self.nonMatchingFrames.append(rawJSON)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func writeAll(_ data: Data) throws {
            guard fd >= 0 else { throw ClientError.closed }
            var written = 0
            while written < data.count {
                let result = data.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress?.advanced(by: written), data.count - written)
                }
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                throw ClientError.posix(operation: "write", code: errno)
            }
        }

        private func readLine() throws -> Data {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    return line
                }
                guard fd >= 0 else { throw ClientError.closed }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 10000)
                if pollResult == 0 { throw ClientError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.posix(operation: "poll", code: errno)
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0,
                   descriptor.revents & Int16(POLLIN) == 0
                {
                    throw ClientError.closed
                }

                var bytes = [UInt8](repeating: 0, count: 4096)
                let readCount = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(fd, storage.baseAddress, storage.count)
                }
                if readCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(readCount))
                    continue
                }
                if readCount == 0 { throw ClientError.closed }
                if errno == EINTR { continue }
                throw ClientError.posix(operation: "read", code: errno)
            }
        }
    }
#endif
