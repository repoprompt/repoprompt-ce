import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class MCPToolExecutionWatchdogIntegrationTests: XCTestCase {
        func testBoundedFileToolsEmitHandlerCompletionAndConnectionRemainsUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let endpoint = try fixture.endpointA()
                    let context = fixture.contextA
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: [
                            "paths": [context.fileURL.path],
                            "context_id": context.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": context.fileURL.path,
                            "context_id": context.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: [
                            "pattern": "distinct_mcp_connection_shared_search_token",
                            "mode": "content",
                            "context_id": context.tabID.uuidString
                        ]
                    )

                    let events = recorder.snapshot().filter { $0.connectionID == endpoint.connectionID }
                    for toolName in [
                        MCPWindowToolName.getCodeStructure,
                        MCPWindowToolName.readFile,
                        MCPWindowToolName.search
                    ] {
                        XCTAssertTrue(events.contains {
                            $0.toolName == toolName && $0.phase == .handlerCompleted
                        }, "Missing handler-completed trace for \(toolName): \(events)")
                    }

                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let isTerminal = await fixture.networkManager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskUserLifecycleExemptionDoesNotInstallExecutionWatchdog() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "ask-user-execution-contract-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser) {
                    await operationGate.enterAndWait()
                    return .object(["timed_out": .bool(false)])
                }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPWindowToolName.askUser],
                    purpose: .agentModeRun
                )

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "ask-user-exemption",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPWindowToolName.askUser]
                    )
                    endpoint = createdEndpoint
                    let responseTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.askUser,
                            arguments: [
                                "questions": [[
                                    "id": "scope",
                                    "question": "Which scope?"
                                ]],
                                "timeout_seconds": 900
                            ]
                        )
                    }

                    try await operationGate.waitUntilEntered(count: 1)
                    for _ in 0 ..< 10 {
                        await Task.yield()
                    }
                    let sleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(sleeperCount, 0)

                    let selected = recorder.snapshot().first {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.askUser
                            && $0.phase == .contractSelected
                    }
                    XCTAssertEqual(selected?.contractKind, .interactiveCancellable)
                    XCTAssertNil(selected?.executionDeadlineSeconds)
                    XCTAssertFalse(recorder.snapshot().contains {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.askUser
                            && $0.phase == .deadlineExpired
                    })

                    await operationGate.release()
                    _ = try await responseTask.value

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await operationGate.release()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.askUser, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testCooperativeDeadlineReturnsOneTimeoutAndKeepsConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let cooperativeGate = MCPExecutionCooperativeCancellationGate()
                let manager = fixture.networkManager
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    try await cooperativeGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let responseTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await cooperativeGate.waitUntilEntered()
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                    let response = try await responseTask.value
                    let text = try Self.toolResultText(response)
                    XCTAssertTrue(text.contains("tool_execution_timeout"), text)
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeDeadlineForceDisconnectsAndQueuedCallNeverEntersProvider() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await operationGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let first = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)

                    let queued = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    await Self.assertSocketClosed(first)
                    await Self.assertSocketClosed(queued)
                    let enteredCount = await operationGate.enteredCount()
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertEqual(enteredCount, 1)
                    XCTAssertTrue(isTerminal)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.readFile
                    }
                    XCTAssertFalse(events.contains { $0.phase == .handlerCompleted })
                    XCTAssertTrue(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertTrue(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private static func assertSocketClosed(_ task: Task<PersistentMCPTestRPCResponse, Error>) async {
            do {
                _ = try await task.value
                XCTFail("Expected socket closure")
            } catch PersistentMCPTestSocketClient.ClientError.closed {
                // Expected.
            } catch {
                XCTFail("Expected socket closure, got \(error)")
            }
        }
    }

    private final class MCPExecutionTraceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [MCPToolExecutionTraceEvent] = []

        func append(_ event: MCPToolExecutionTraceEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [MCPToolExecutionTraceEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private actor MCPExecutionCooperativeCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var entered = false
        private var continuation: CheckedContinuation<Void, Error>?

        func enterAndWait() async throws {
            entered = true
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        func waitUntilEntered(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !entered {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateDidNotEnter
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        private func cancel() {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    actor MCPExecutionIgnoringCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var count = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            count += 1
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered(
            count expected: Int,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while count < expected {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: expected,
                        actual: count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func enteredCount() -> Int {
            count
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private enum MCPExecutionWatchdogIntegrationFixtureError: Error {
        case cooperativeGateDidNotEnter
        case gateDidNotEnter(expected: Int, actual: Int)
    }

#endif
