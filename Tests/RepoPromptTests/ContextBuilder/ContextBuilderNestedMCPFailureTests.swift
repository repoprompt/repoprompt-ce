import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderNestedMCPFailureTests: XCTestCase {
        func testNestedReadHandlerCompletesThenExactResponseDeliveryFailureSettlesOuterContextBuilder() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let state = NestedContextBuilderFailureState()
                let bridge = NestedMCPResponseDeliveryFaultBridge()
                let factory = NestedContextBuilderProviderFactory(
                    mode: .responseDeliveryFailure(bridge),
                    state: state
                )
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextBuilderProviderFactory: factory.makeProvider
                )
                try await Self.activateWorkspace(fixture.contextA)
                factory.configure(
                    networkManager: fixture.networkManager,
                    filePath: fixture.contextA.fileURL.path,
                    tabID: fixture.contextA.tabID
                )
                let recorder = NestedContextBuilderExecutionTraceRecorder()
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                defer { MCPToolExecutionTracer.setTestSink(nil) }

                do {
                    let outerEndpoint = try fixture.endpointA()
                    let response = try await outerEndpoint.callTool(
                        name: MCPWindowToolName.contextBuilder,
                        arguments: [
                            "instructions": "Read the fixture file and then report the delivery failure.",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let nestedConnectionID = try await state.requireNestedConnectionID()
                    let events = recorder.snapshot()

                    XCTAssertTrue(events.contains {
                        $0.connectionID == nestedConnectionID &&
                            $0.toolName == MCPWindowToolName.readFile &&
                            $0.phase == .handlerCompleted
                    })
                    let providerFailureCount = await state.providerFailureCount()
                    XCTAssertEqual(providerFailureCount, 1)
                    let deliverySnapshot = await bridge.snapshot()
                    XCTAssertEqual(deliverySnapshot.terminalReason, "fault_injected_fail_destination_write")
                    XCTAssertFalse(deliverySnapshot.canReconnect)
                    XCTAssertTrue(try Self.toolResultText(response).contains("failed:"))

                    let outerContracts = events.filter {
                        $0.connectionID == outerEndpoint.connectionID &&
                            $0.toolName == MCPWindowToolName.contextBuilder &&
                            $0.phase == .contractSelected
                    }
                    XCTAssertEqual(outerContracts.count, 1)
                    XCTAssertEqual(outerContracts.first?.contractKind, .longSynchronousCancellable)
                    XCTAssertNil(outerContracts.first?.executionDeadlineSeconds)

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

        func testNestedReadHandlerNeverReturnsAndWatchdogDisconnectSettlesOuterContextBuilder() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let state = NestedContextBuilderFailureState()
                let gate = MCPExecutionIgnoringCancellationGate()
                let factory = NestedContextBuilderProviderFactory(
                    mode: .uncooperativeHandler,
                    state: state
                )
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextBuilderProviderFactory: factory.makeProvider
                )
                try await Self.activateWorkspace(fixture.contextA)
                factory.configure(
                    networkManager: fixture.networkManager,
                    filePath: fixture.contextA.fileURL.path,
                    tabID: fixture.contextA.tabID
                )
                let clock = ExecutionWatchdogManualClock()
                let manager = fixture.networkManager
                let recorder = NestedContextBuilderExecutionTraceRecorder()
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                defer { MCPToolExecutionTracer.setTestSink(nil) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await gate.enterAndWait()
                    return .null
                }

                do {
                    let outerEndpoint = try fixture.endpointA()
                    let responseTask = Task {
                        try await outerEndpoint.callTool(
                            name: MCPWindowToolName.contextBuilder,
                            arguments: [
                                "instructions": "Read the fixture file and surface any nested MCP failure.",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }

                    let nestedConnectionID = try await state.requireNestedConnectionID()
                    try await clock.waitForSleeperCount(1)
                    try await gate.waitUntilEntered(count: 1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let response = try await responseTask.value
                    let events = recorder.snapshot()
                    let nestedEvents = events.filter {
                        $0.connectionID == nestedConnectionID &&
                            $0.toolName == MCPWindowToolName.readFile
                    }
                    XCTAssertFalse(nestedEvents.contains { $0.phase == .handlerCompleted })
                    XCTAssertTrue(nestedEvents.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertTrue(nestedEvents.contains { $0.phase == .connectionForceDisconnectRequested })
                    let nestedConnectionIsTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: nestedConnectionID
                    )
                    XCTAssertTrue(nestedConnectionIsTerminal)
                    let providerFailureCount = await state.providerFailureCount()
                    XCTAssertEqual(providerFailureCount, 1)
                    XCTAssertTrue(try Self.toolResultText(response).contains("failed:"))

                    let outerContracts = events.filter {
                        $0.connectionID == outerEndpoint.connectionID &&
                            $0.toolName == MCPWindowToolName.contextBuilder &&
                            $0.phase == .contractSelected
                    }
                    XCTAssertEqual(outerContracts.count, 1)
                    XCTAssertEqual(outerContracts.first?.contractKind, .longSynchronousCancellable)
                    XCTAssertNil(outerContracts.first?.executionDeadlineSeconds)

                    await gate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await gate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderNestedMCPFailureTests"
            )
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }
    }

    @MainActor
    private final class NestedContextBuilderProviderFactory {
        private struct Configuration {
            let networkManager: ServerNetworkManager
            let filePath: String
            let tabID: UUID
        }

        private let mode: NestedContextBuilderProvider.Mode
        private let state: NestedContextBuilderFailureState
        private var configuration: Configuration?

        init(mode: NestedContextBuilderProvider.Mode, state: NestedContextBuilderFailureState) {
            self.mode = mode
            self.state = state
        }

        func configure(networkManager: ServerNetworkManager, filePath: String, tabID: UUID) {
            configuration = Configuration(
                networkManager: networkManager,
                filePath: filePath,
                tabID: tabID
            )
        }

        func makeProvider(
            agent: AgentProviderKind,
            modelString: String?,
            workspacePath: String?
        ) -> HeadlessAgentProvider {
            _ = modelString
            _ = workspacePath
            guard let configuration else {
                preconditionFailure("Nested Context Builder provider factory used before fixture configuration")
            }
            guard let clientName = agent.mcpClientNameHint else {
                preconditionFailure("Selected Context Builder agent has no MCP client name")
            }
            return NestedContextBuilderProvider(
                mode: mode,
                state: state,
                networkManager: configuration.networkManager,
                filePath: configuration.filePath,
                tabID: configuration.tabID,
                clientName: clientName
            )
        }
    }

    private final class NestedContextBuilderProvider: HeadlessAgentProvider {
        enum Mode {
            case responseDeliveryFailure(NestedMCPResponseDeliveryFaultBridge)
            case uncooperativeHandler
        }

        private let mode: Mode
        private let state: NestedContextBuilderFailureState
        private let networkManager: ServerNetworkManager
        private let filePath: String
        private let tabID: UUID
        private let clientName: String

        init(
            mode: Mode,
            state: NestedContextBuilderFailureState,
            networkManager: ServerNetworkManager,
            filePath: String,
            tabID: UUID,
            clientName: String
        ) {
            self.mode = mode
            self.state = state
            self.networkManager = networkManager
            self.filePath = filePath
            self.tabID = tabID
            self.clientName = clientName
        }

        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            _ = message
            guard runID != nil else { throw CancellationError() }
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: "nested-context-builder",
                networkManager: networkManager,
                clientName: clientName,
                requiredToolNames: [MCPWindowToolName.readFile]
            )
            await state.recordNestedConnectionID(endpoint.connectionID)

            do {
                switch mode {
                case let .responseDeliveryFailure(bridge):
                    let requestID = endpoint.client.nextRequestIDForTesting()
                    try await bridge.prepareExactReadFileFault(requestID: requestID)
                    endpoint.client.installResponseInterceptor(for: requestID) { rawJSON in
                        try await bridge.interceptResponse(rawJSON, requestID: requestID)
                    }
                case .uncooperativeHandler:
                    break
                }

                _ = try await endpoint.callTool(
                    name: MCPWindowToolName.readFile,
                    arguments: [
                        "path": filePath,
                        "context_id": tabID.uuidString
                    ]
                )
                await cleanup(endpoint)
                throw NestedContextBuilderFailureError.nestedCallUnexpectedlySucceeded
            } catch {
                await state.recordProviderFailure()
                await cleanup(endpoint)
                throw error
            }
        }

        func dispose() async {}

        private func cleanup(_ endpoint: PersistentMCPTestEndpoint) async {
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await networkManager.debugRemoveConnection(endpoint.connectionID)
            await networkManager.clearClientConnectionPolicy(for: endpoint.clientName)
            await networkManager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }
    }

    private actor NestedContextBuilderFailureState {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var nestedConnectionID: UUID?
        private var nestedConnectionWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]
        private var failedNestedConnectionWaiters: [UUID: Error] = [:]
        private var grantedNestedConnectionWaiterIDs: Set<UUID> = []
        private var failureCount = 0

        func recordNestedConnectionID(_ id: UUID) {
            nestedConnectionID = id
            failedNestedConnectionWaiters.removeAll()
            let waiters = nestedConnectionWaiters
            nestedConnectionWaiters.removeAll()
            grantedNestedConnectionWaiterIDs.formUnion(waiters.keys)
            waiters.values.forEach { $0.resume(returning: id) }
        }

        func requireNestedConnectionID(
            timeout: Duration = synchronizationTimeout
        ) async throws -> UUID {
            if let nestedConnectionID { return nestedConnectionID }

            let waiterID = UUID()
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    await self.failNestedConnectionWaiter(
                        id: waiterID,
                        error: NestedContextBuilderFailureError.nestedConnectionDidNotRegister
                    )
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }

            do {
                let id = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        registerNestedConnectionWaiter(id: waiterID, continuation: continuation)
                    }
                } onCancel: {
                    Task {
                        await self.failNestedConnectionWaiter(id: waiterID, error: CancellationError())
                    }
                }
                grantedNestedConnectionWaiterIDs.remove(waiterID)
                try Task.checkCancellation()
                timeoutTask.cancel()
                return id
            } catch {
                timeoutTask.cancel()
                throw error
            }
        }

        private func registerNestedConnectionWaiter(
            id: UUID,
            continuation: CheckedContinuation<UUID, Error>
        ) {
            if let nestedConnectionID {
                continuation.resume(returning: nestedConnectionID)
            } else if let error = failedNestedConnectionWaiters.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            } else {
                nestedConnectionWaiters[id] = continuation
            }
        }

        private func failNestedConnectionWaiter(id: UUID, error: Error) async {
            if let continuation = nestedConnectionWaiters.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            } else if nestedConnectionID == nil, !grantedNestedConnectionWaiterIDs.contains(id) {
                failedNestedConnectionWaiters[id] = error
            }
        }

        func recordProviderFailure() {
            failureCount += 1
        }

        func providerFailureCount() -> Int {
            failureCount
        }
    }

    private actor NestedMCPResponseDeliveryFaultBridge {
        private let ledger = JSONRPCBridgeLedger()

        func prepareExactReadFileFault(requestID: Int) async throws {
            _ = try await ledger.beginConnection()
            let request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/call",
                "params": [
                    "name": MCPWindowToolName.readFile,
                    "arguments": [:]
                ]
            ], options: [.sortedKeys]) + Data([0x0A])
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: request,
                direction: .clientToServer,
                ledger: ledger
            ) { _ in }
        }

        func interceptResponse(_ rawJSON: String, requestID: Int) async throws -> String {
            let response = Data(rawJSON.utf8) + Data([0x0A])
            let fault = JSONRPCBridgeFaultRule(
                direction: .serverToClient,
                id: .number(Int64(requestID)),
                method: "tools/call",
                tool: MCPWindowToolName.readFile
            )
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response,
                direction: .serverToClient,
                ledger: ledger,
                faultRule: fault
            ) { _ in }
            return rawJSON
        }

        func snapshot() async -> JSONRPCBridgeLedgerSnapshot {
            await ledger.snapshot()
        }
    }

    private final class NestedContextBuilderExecutionTraceRecorder: @unchecked Sendable {
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

    private enum NestedContextBuilderFailureError: Error {
        case nestedCallUnexpectedlySucceeded
        case nestedConnectionDidNotRegister
    }
#endif
