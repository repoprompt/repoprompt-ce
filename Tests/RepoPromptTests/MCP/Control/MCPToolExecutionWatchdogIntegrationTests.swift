import Foundation
import JSONSchema
import MCP
@testable import RepoPromptApp
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

        func testSameWindowExclusiveResourceReleasesBeforeCompletionObserverTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointARead()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let observerTailGate = MCPExecutionIgnoringCancellationGate()
                var firstTask: Task<PersistentMCPTestRPCResponse, Error>?
                var secondTask: Task<PersistentMCPTestRPCResponse, Error>?

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.manageSelection) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolCompletionObserversForTesting { connectionID, toolName in
                    guard connectionID == firstEndpoint.connectionID,
                          toolName == MCPWindowToolName.manageSelection
                    else { return }
                    await observerTailGate.enterAndWait()
                }

                do {
                    let arguments: [String: Any] = [
                        "op": "get",
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let blockedFirst = Task {
                        try await firstEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: arguments
                        )
                    }
                    firstTask = blockedFirst
                    try await observerTailGate.waitUntilEntered(count: 1)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)

                    let firstLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: firstEndpoint.connectionID,
                        lane: .ordinary
                    )
                    XCTAssertEqual(firstLimiter?.activePermitCount, 1)

                    let competingSecond = Task {
                        try await secondEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: arguments
                        )
                    }
                    secondTask = competingSecond
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)
                    _ = try await competingSecond.value
                    secondTask = nil

                    await observerTailGate.release()
                    _ = try await blockedFirst.value
                    firstTask = nil

                    await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await observerTailGate.release()
                    firstTask?.cancel()
                    secondTask?.cancel()
                    if let firstTask { _ = try? await firstTask.value }
                    if let secondTask { _ = try? await secondTask.value }
                    await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.manageSelection,
                        operation: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testSameWindowSmallReadResourcesReleaseBeforeFormattingTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointARead()
                let thirdEndpoint = try fixture.endpointAQueuedSearch()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let formattingTailGate = MCPExecutionIgnoringCancellationGate()
                let blockedConnectionIDs = Set([firstEndpoint.connectionID, secondEndpoint.connectionID])
                var tasks: [Task<PersistentMCPTestRPCResponse, Error>] = []

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard blockedConnectionIDs.contains(connectionID),
                          toolName == MCPWindowToolName.readFile
                    else { return }
                    await formattingTailGate.enterAndWait()
                }

                do {
                    let arguments: [String: Any] = [
                        "path": fixture.contextA.fileURL.path,
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let first = Task {
                        try await firstEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    let second = Task {
                        try await secondEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    tasks = [first, second]
                    try await formattingTailGate.waitUntilEntered(count: 2)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)

                    for endpoint in [firstEndpoint, secondEndpoint] {
                        let limiter = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: endpoint.connectionID,
                            lane: .smallRead
                        )
                        XCTAssertEqual(limiter?.activePermitCount, 1)
                    }

                    let third = Task {
                        try await thirdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: arguments
                        )
                    }
                    tasks.append(third)
                    try await providerProbe.waitUntilEntered(connectionID: thirdEndpoint.connectionID)
                    _ = try await third.value
                    tasks.removeLast()

                    await formattingTailGate.release()
                    _ = try await first.value
                    _ = try await second.value
                    tasks.removeAll()

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await formattingTailGate.release()
                    tasks.forEach { $0.cancel() }
                    for task in tasks {
                        _ = try? await task.value
                    }
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAppWideExclusiveResourceReleasesBeforeFormattingTail() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let firstEndpoint = try fixture.endpointA()
                let secondEndpoint = try fixture.endpointB()
                let providerProbe = MCPPostProviderAdmissionProbe()
                let formattingTailGate = MCPExecutionIgnoringCancellationGate()
                var appSettingsScope: MCPAppSettingsServiceScope?
                var firstTask: Task<PersistentMCPTestRPCResponse, Error>?
                var secondTask: Task<PersistentMCPTestRPCResponse, Error>?

                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.appSettings) {
                    await providerProbe.record(connectionID: ServerNetworkManager.currentConnectionID)
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard connectionID == firstEndpoint.connectionID,
                          toolName == MCPGlobalToolName.appSettings
                    else { return }
                    await formattingTailGate.enterAndWait()
                }

                do {
                    let installedScope = try await MCPAppSettingsServiceScope.install()
                    appSettingsScope = installedScope
                    let arguments: [String: Any] = [
                        "op": "get",
                        "key": "ui.appearance_mode",
                        "_rawJSON": true
                    ]
                    let blockedFirst = Task {
                        try await firstEndpoint.callTool(
                            name: MCPGlobalToolName.appSettings,
                            arguments: arguments
                        )
                    }
                    firstTask = blockedFirst
                    try await formattingTailGate.waitUntilEntered(count: 1)
                    try await providerProbe.waitUntilEntered(connectionID: firstEndpoint.connectionID)

                    let firstLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: firstEndpoint.connectionID,
                        lane: .ordinary
                    )
                    XCTAssertEqual(firstLimiter?.activePermitCount, 1)

                    let competingSecond = Task {
                        try await secondEndpoint.callTool(
                            name: MCPGlobalToolName.appSettings,
                            arguments: arguments
                        )
                    }
                    secondTask = competingSecond
                    try await providerProbe.waitUntilEntered(connectionID: secondEndpoint.connectionID)
                    _ = try await competingSecond.value
                    secondTask = nil

                    await formattingTailGate.release()
                    _ = try await blockedFirst.value
                    firstTask = nil

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.appSettings,
                        operation: nil
                    )
                    await installedScope.restore()
                    installedScope.assertRestored()
                    appSettingsScope = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await formattingTailGate.release()
                    firstTask?.cancel()
                    secondTask?.cancel()
                    if let firstTask { _ = try? await firstTask.value }
                    if let secondTask { _ = try? await secondTask.value }
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.appSettings,
                        operation: nil
                    )
                    if let appSettingsScope {
                        await appSettingsScope.restore()
                        appSettingsScope.assertRestored()
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageSelectionAndFileActionsReportReplyConstructionPhase() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let createdFileURL = fixture.contextA.fileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("watchdog-phase-\(UUID().uuidString).txt")
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.fileActions,
                        arguments: [
                            "action": "create",
                            "path": createdFileURL.path,
                            "content": "watchdog phase fixture\n",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )

                    let events = recorder.snapshot().filter { $0.connectionID == endpoint.connectionID }
                    let selectionCompleted = try XCTUnwrap(events.last {
                        $0.toolName == MCPWindowToolName.manageSelection && $0.phase == .handlerCompleted
                    })
                    XCTAssertEqual(selectionCompleted.handlerPhase?.phase, .manageSelectionReplyConstruction)
                    XCTAssertEqual(selectionCompleted.handlerPhase?.transition, .completed)

                    let fileActionCompleted = try XCTUnwrap(events.last {
                        $0.toolName == MCPWindowToolName.fileActions && $0.phase == .handlerCompleted
                    })
                    XCTAssertEqual(fileActionCompleted.handlerPhase?.phase, .fileActionsReplyConstruction)
                    XCTAssertEqual(fileActionCompleted.handlerPhase?.transition, .completed)

                    MCPToolExecutionTracer.setTestSink(nil)
                    try? FileManager.default.removeItem(at: createdFileURL)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    try? FileManager.default.removeItem(at: createdFileURL)
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

        func testLongRunningFileSearchSurvivesFormerWatchdogAndHonorsCallerCancellation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let survivalGate = MCPExecutionIgnoringCancellationGate()
                let cancellationGate = MCPExecutionCooperativeCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search) {
                    await survivalGate.enterAndWait()
                    return .object(["phase": .string("survived-former-watchdog")])
                }

                var survivalTask: Task<PersistentMCPTestRPCResponse, Error>?
                var cancellationTask: Task<PersistentMCPTestRPCResponse, Error>?
                do {
                    let activeSurvivalTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: [
                                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                                "mode": "content",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    survivalTask = activeSurvivalTask
                    try await survivalGate.waitUntilEntered(count: 1)
                    let survivalSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(survivalSleeperCount, 0)
                    let formerWatchdogWindow = MCPTimeoutPolicy.boundedToolExecutionDeadline
                        + MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
                        + .seconds(1)
                    try await clock.advanceWithoutSleepers(by: formerWatchdogWindow)
                    for _ in 0 ..< 20 {
                        await Task.yield()
                    }
                    let survivalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    let survivalTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertTrue(survivalInFlight)
                    XCTAssertFalse(survivalTerminal)
                    let survivalViable = await endpoint.connectionManager.isViableForRetention()
                    XCTAssertTrue(survivalViable)
                    let survivalEvents = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.search
                    }
                    let selected = try XCTUnwrap(survivalEvents.first { $0.phase == .contractSelected })
                    XCTAssertEqual(selected.contractKind, .longSynchronousCancellable)
                    XCTAssertNil(selected.executionDeadlineSeconds)
                    XCTAssertNil(selected.cleanupGraceSeconds)
                    XCTAssertFalse(survivalEvents.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(survivalEvents.contains { $0.phase == .connectionForceDisconnectRequested })

                    await survivalGate.release()
                    _ = try await activeSurvivalTask.value

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search) {
                        try await cancellationGate.enterAndWait()
                        return .object(["phase": .string("unexpected-completion")])
                    }
                    let cancellationRequestID = endpoint.client.nextRequestIDForTesting()
                    let activeCancellationTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.search,
                            arguments: [
                                "pattern": PersistentMCPTestFixture.sharedSearchToken,
                                "mode": "content",
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    cancellationTask = activeCancellationTask
                    try await cancellationGate.waitUntilEntered()
                    let cancellationSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(cancellationSleeperCount, 0)
                    try endpoint.client.sendNotification(
                        method: "notifications/cancelled",
                        params: ["requestId": cancellationRequestID]
                    )
                    try await cancellationGate.waitUntilCancellationObserved()
                    let observedCancellationCount = await cancellationGate.observedCancellationCount()
                    XCTAssertEqual(observedCancellationCount, 1)
                    let cancellationResponse = try await activeCancellationTask.value
                    let cancellationText = try Self.toolResultText(cancellationResponse)
                    XCTAssertFalse(cancellationText.contains("tool_execution_timeout"), cancellationText)
                    XCTAssertFalse(cancellationText.contains("tool_execution_cleanup_unresponsive"), cancellationText)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.search
                    }
                    XCTAssertEqual(events.count(where: { $0.phase == .contractSelected }), 2)
                    XCTAssertTrue(events.filter { $0.phase == .contractSelected }.allSatisfy {
                        $0.contractKind == .longSynchronousCancellable
                            && $0.executionDeadlineSeconds == nil
                            && $0.cleanupGraceSeconds == nil
                    })
                    XCTAssertFalse(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })
                    let cancellationTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(cancellationTerminal)

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    MCPToolExecutionTracer.setTestSink(nil)

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: [
                            "pattern": PersistentMCPTestFixture.sharedSearchToken,
                            "mode": "content",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let finalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    XCTAssertFalse(finalInFlight)
                    let limiter = await manager.connectionLimiterSnapshotForTesting(connectionID: endpoint.connectionID)
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await survivalGate.release()
                    await cancellationGate.cancelForCleanup()
                    survivalTask?.cancel()
                    cancellationTask?.cancel()
                    if let survivalTask {
                        _ = try? await survivalTask.value
                    }
                    if let cancellationTask {
                        _ = try? await cancellationTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.search, operation: nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testBoundedWindowAndGlobalDispatchBranchesReturnOneTimeoutAndKeepConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let cases: [(
                    label: String,
                    toolName: String,
                    arguments: [String: Any]
                )] = [
                    (
                        label: "window-scoped read_file",
                        toolName: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    ),
                    (
                        label: "global app_settings",
                        toolName: MCPGlobalToolName.appSettings,
                        arguments: [
                            "op": "get",
                            "key": "ui.appearance_mode"
                        ]
                    )
                ]
                var appSettingsScope: MCPAppSettingsServiceScope?
                var activeToolName: String?
                var activeGate: MCPExecutionCooperativeCancellationGate?
                var activeResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                do {
                    let installedAppSettingsScope = try await MCPAppSettingsServiceScope.install()
                    appSettingsScope = installedAppSettingsScope
                    let endpoint = try fixture.endpointA()
                    for testCase in cases {
                        let clock = ExecutionWatchdogManualClock()
                        let cooperativeGate = MCPExecutionCooperativeCancellationGate()
                        activeToolName = testCase.toolName
                        activeGate = cooperativeGate
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName) {
                            try await cooperativeGate.enterAndWait()
                            return .null
                        }

                        let responseTask = Task {
                            try await endpoint.callTool(
                                name: testCase.toolName,
                                arguments: testCase.arguments
                            )
                        }
                        activeResponseTask = responseTask
                        try await clock.waitForSleeperCount(1)
                        let sleeperCount = await clock.sleeperCount()
                        XCTAssertEqual(sleeperCount, 1, testCase.label)
                        try await cooperativeGate.waitUntilEntered()
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

                        let response = try await responseTask.value
                        activeResponseTask = nil
                        let cancellationCount = await cooperativeGate.observedCancellationCount()
                        XCTAssertEqual(cancellationCount, 1, testCase.label)
                        let text = try Self.toolResultText(response)
                        XCTAssertEqual(
                            text.components(separatedBy: "tool_execution_timeout").count - 1,
                            1,
                            "\(testCase.label): \(text)"
                        )
                        let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                        XCTAssertFalse(isTerminal, testCase.label)

                        let events = recorder.snapshot().filter {
                            $0.connectionID == endpoint.connectionID && $0.toolName == testCase.toolName
                        }
                        XCTAssertEqual(events.count(where: { $0.phase == .contractSelected }), 1, testCase.label)
                        XCTAssertEqual(events.count(where: { $0.phase == .deadlineExpired }), 1, testCase.label)
                        let selected = try XCTUnwrap(
                            events.first { $0.phase == .contractSelected },
                            testCase.label
                        )
                        XCTAssertEqual(selected.contractKind, .bounded, testCase.label)
                        XCTAssertEqual(
                            selected.executionDeadlineSeconds,
                            Double(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds),
                            testCase.label
                        )

                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName, operation: nil)
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        activeToolName = nil
                        activeGate = nil
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    let appSettingsResponse = try await endpoint.callTool(
                        name: MCPGlobalToolName.appSettings,
                        arguments: [
                            "op": "get",
                            "key": "ui.appearance_mode",
                            "_rawJSON": true
                        ]
                    )
                    let appSettingsPayload = try Self.toolResultObject(appSettingsResponse)
                    XCTAssertEqual(appSettingsPayload["op"] as? String, "get")
                    XCTAssertEqual(appSettingsPayload["status"] as? String, "ok")
                    XCTAssertEqual((appSettingsPayload["count"] as? NSNumber)?.intValue, 1)
                    let appSettingsValues = try XCTUnwrap(appSettingsPayload["values"] as? [String: Any])
                    XCTAssertNotNil(appSettingsValues["ui.appearance_mode"])

                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    let readFileResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let readFileText = try Self.toolResultText(readFileResponse)
                    XCTAssertTrue(readFileText.contains(fixture.contextA.sentinel), readFileText)
                    let finalInFlight = await manager.hasInFlightCalls(for: endpoint.connectionID)
                    XCTAssertFalse(finalInFlight)
                    let limiter = await manager.connectionLimiterSnapshotForTesting(connectionID: endpoint.connectionID)
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await installedAppSettingsScope.restore()
                    installedAppSettingsScope.assertRestored()
                    appSettingsScope = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await activeGate?.cancelForCleanup()
                    activeResponseTask?.cancel()
                    if let activeResponseTask {
                        _ = try? await activeResponseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    if let activeToolName {
                        await manager.debugSetResolvedToolOperationOverride(toolName: activeToolName, operation: nil)
                    }
                    for testCase in cases {
                        await manager.debugSetResolvedToolOperationOverride(toolName: testCase.toolName, operation: nil)
                    }
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let appSettingsScope {
                        await appSettingsScope.restore()
                        appSettingsScope.assertRestored()
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageWorkspacesSwitchTimeoutReleasesPermitAndKeepsConnectionUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionCooperativeCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-cooperative-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?
                var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                    try await operationGate.enterAndWait()
                    return .null
                }

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-cooperative",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    let activeResponseTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "switch",
                                "workspace": fixture.contextA.workspaceID.uuidString,
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    responseTask = activeResponseTask
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered()
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline)

                    let response = try await activeResponseTask.value
                    responseTask = nil
                    let cancellationCount = await operationGate.observedCancellationCount()
                    XCTAssertEqual(cancellationCount, 1)
                    let text = try Self.toolResultText(response)
                    XCTAssertEqual(text.components(separatedBy: "tool_execution_timeout").count - 1, 1, text)
                    XCTAssertTrue(text.contains("120-second execution contract"), text)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPGlobalToolName.manageWorkspaces
                    }
                    let selected = try XCTUnwrap(events.first { $0.phase == .contractSelected })
                    XCTAssertEqual(selected.contractKind, .bounded)
                    XCTAssertEqual(
                        selected.executionDeadlineSeconds,
                        Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                    )
                    XCTAssertEqual(
                        selected.cleanupGraceSeconds,
                        Double(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds)
                    )
                    XCTAssertEqual(events.count(where: { $0.phase == .deadlineExpired }), 1)
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertFalse(isTerminal)

                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    MCPToolExecutionTracer.setTestSink(nil)

                    let listResponse = try await createdEndpoint.callTool(
                        name: MCPGlobalToolName.manageWorkspaces,
                        arguments: ["action": "list"]
                    )
                    let listText = try Self.toolResultText(listResponse)
                    XCTAssertFalse(listText.contains("tool_execution_timeout"), listText)
                    _ = try await createdEndpoint.client.request(method: "tools/list", params: [:])
                    let limiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(limiter?.permits, 1)
                    XCTAssertEqual(limiter?.waiterCount, 0)
                    XCTAssertEqual(limiter?.inFlight, 0)

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await operationGate.cancelForCleanup()
                    responseTask?.cancel()
                    if let responseTask {
                        _ = try? await responseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testManageWorkspacesCreateDeleteAndListSelectExactContracts() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-classification-\(UUID().uuidString)"
                let cases: [(label: String, arguments: [String: Any], isBounded: Bool)] = [
                    ("create default", ["action": "create"], true),
                    ("create true", ["action": "create", "switch_to_created": true], true),
                    ("create false", ["action": "create", "switch_to_created": false], false),
                    ("delete close", ["action": "delete", "close_window": true], true),
                    ("delete default", ["action": "delete"], false),
                    ("delete no close", ["action": "delete", "close_window": false], false),
                    ("list", ["action": "list"], false)
                ]
                var endpoint: PersistentMCPTestEndpoint?
                var activeGate: MCPExecutionIgnoringCancellationGate?
                var activeResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-classification",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    for (index, testCase) in cases.enumerated() {
                        let clock = ExecutionWatchdogManualClock()
                        let operationGate = MCPExecutionIgnoringCancellationGate()
                        activeGate = operationGate
                        let label = testCase.label
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                        await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                            await operationGate.enterAndWait()
                            return .object([
                                "action": .string(label),
                                "status": .string("ok")
                            ])
                        }

                        var arguments = testCase.arguments
                        arguments["window_id"] = fixture.contextA.window.windowID
                        let responseTask = Task {
                            try await createdEndpoint.callTool(
                                name: MCPGlobalToolName.manageWorkspaces,
                                arguments: arguments
                            )
                        }
                        activeResponseTask = responseTask
                        try await operationGate.waitUntilEntered(count: 1)
                        if testCase.isBounded {
                            try await clock.waitForSleeperCount(1)
                        } else {
                            for _ in 0 ..< 20 {
                                await Task.yield()
                            }
                            let sleeperCount = await clock.sleeperCount()
                            XCTAssertEqual(sleeperCount, 0, testCase.label)
                        }

                        let selectedEvents = recorder.snapshot().filter {
                            $0.connectionID == createdEndpoint.connectionID
                                && $0.toolName == MCPGlobalToolName.manageWorkspaces
                                && $0.phase == .contractSelected
                        }
                        XCTAssertEqual(selectedEvents.count, index + 1, testCase.label)
                        let selected = try XCTUnwrap(selectedEvents.last, testCase.label)
                        XCTAssertEqual(
                            selected.contractKind,
                            testCase.isBounded ? .bounded : .workspaceLifecycleCancellable,
                            testCase.label
                        )
                        XCTAssertEqual(
                            selected.executionDeadlineSeconds,
                            testCase.isBounded
                                ? Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                                : nil,
                            testCase.label
                        )

                        await operationGate.release()
                        _ = try await responseTask.value
                        activeResponseTask = nil
                        activeGate = nil
                        await manager.debugSetResolvedToolOperationOverride(
                            toolName: MCPGlobalToolName.manageWorkspaces,
                            operation: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    let terminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertFalse(terminal)
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await activeGate?.release()
                    activeResponseTask?.cancel()
                    if let activeResponseTask {
                        _ = try? await activeResponseTask.value
                    }
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeManageWorkspacesSwitchForceDisconnectsAndBlocksQueuedProviderEntry() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let clientName = "manage-workspaces-uncooperative-\(UUID().uuidString)"
                var endpoint: PersistentMCPTestEndpoint?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: fixture.contextA.window.windowID,
                    restrictedTools: [],
                    tabID: fixture.contextA.tabID,
                    runID: UUID(),
                    additionalTools: [MCPGlobalToolName.manageWorkspaces],
                    purpose: .agentModeRun
                )
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPGlobalToolName.manageWorkspaces) {
                    await operationGate.enterAndWait()
                    return .null
                }

                do {
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "manage-workspaces-uncooperative",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [MCPGlobalToolName.manageWorkspaces]
                    )
                    endpoint = createdEndpoint
                    let first = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "switch",
                                "workspace": fixture.contextA.workspaceID.uuidString,
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered(count: 1)

                    let queued = Task {
                        try await createdEndpoint.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "list",
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    for _ in 0 ..< 1000 {
                        let waiterCount = await manager.connectionLimiterSnapshotForTesting(
                            connectionID: createdEndpoint.connectionID
                        )?.waiterCount
                        if waiterCount == 1 { break }
                        await Task.yield()
                    }
                    let queuedLimiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(queuedLimiter?.waiterCount, 1)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    await Self.assertSocketClosed(first)
                    await Self.assertSocketClosed(queued)
                    let enteredCount = await operationGate.enteredCount()
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdEndpoint.connectionID
                    )
                    XCTAssertEqual(enteredCount, 1)
                    XCTAssertTrue(isTerminal)

                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPGlobalToolName.manageWorkspaces
                    }
                    let selected = try XCTUnwrap(events.first { $0.phase == .contractSelected })
                    XCTAssertEqual(
                        selected.executionDeadlineSeconds,
                        Double(MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds)
                    )
                    XCTAssertFalse(events.contains { $0.phase == .handlerCompleted })
                    XCTAssertTrue(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertTrue(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let endpoint {
                        await Self.cleanupEndpoint(endpoint, manager: manager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealManageSelectionDrainTimeoutSettlesDuringGraceAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                var endpoint: PersistentMCPTestEndpoint?
                var manageTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "real-manage-selection-watchdog-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "real-manage-selection-watchdog",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    _ = try await readTask.value

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeManageTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: ["op": "get"]
                        )
                    }
                    manageTask = activeManageTask
                    try await clock.waitForSleeperCount(1)
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)

                    let activeQueuedReadTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeManageTask.value
                    manageTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount, 0)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount, 1)

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: createdEndpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.manageSelection
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get"]
                    )
                    _ = try await createdEndpoint.client.request(method: "tools/list", params: [:])

                    MCPToolExecutionTracer.setTestSink(nil)
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    manageTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let manageTask { _ = try? await manageTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealFileActionTimeoutDetachesIOReconcilesCatalogAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                try await store.startWatchingRoot(id: fixture.contextA.rootID)
                let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                let service = try XCTUnwrap(loadedService)
                let createdURL = fixture.contextA.rootURL.appendingPathComponent("CreatedAfterWatchdog.swift")
                var fileActionTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await service.setMutationIOWillBeginHandlerForTesting { operation in
                    guard operation == .create else { return }
                    await gate.enterAndWait()
                }
                do {
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeFileActionTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.fileActions,
                            arguments: [
                                "action": "create",
                                "path": createdURL.path,
                                "content": SwiftFixtureSource.emptyStruct("CreatedAfterWatchdog")
                            ]
                        )
                    }
                    fileActionTask = activeFileActionTask
                    try await clock.waitForSleeperCount(1)
                    try await gate.waitUntilEntered(count: 1)

                    let activeQueuedReadTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeFileActionTask.value
                    fileActionTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    let pendingWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(pendingWaiters, 0)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.fileActions
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    let reconciled = await Self.waitUntil {
                        guard FileManager.default.fileExists(atPath: createdURL.path) else { return false }
                        return await store.file(
                            rootID: fixture.contextA.rootID,
                            relativePath: "CreatedAfterWatchdog.swift"
                        ) != nil
                    }
                    XCTAssertTrue(reconciled)
                    let finalWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(finalWaiters, 0)

                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    fileActionTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let fileActionTask { _ = try? await fileActionTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRealFileActionOverwriteTimeoutDetachesIOReconcilesCatalogAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let relativePath = "OverwriteAfterWatchdog.swift"
                let fileURL = fixture.contextA.rootURL.appendingPathComponent(relativePath)
                _ = try await store.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: relativePath,
                    content: "old"
                )
                try await store.startWatchingRoot(id: fixture.contextA.rootID)
                let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                let service = try XCTUnwrap(loadedService)
                var fileActionTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await service.setMutationIOWillBeginHandlerForTesting { operation in
                    guard operation == .edit else { return }
                    await gate.enterAndWait()
                }
                do {
                    let endpoint = try fixture.endpointA()
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeFileActionTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.fileActions,
                            arguments: [
                                "action": "create",
                                "path": fileURL.path,
                                "content": "new",
                                "if_exists": "overwrite"
                            ]
                        )
                    }
                    fileActionTask = activeFileActionTask
                    try await clock.waitForSleeperCount(1)
                    try await gate.waitUntilEntered(count: 1)

                    let activeQueuedReadTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeFileActionTask.value
                    fileActionTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    let pendingWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(pendingWaiters, 0)
                    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "old")

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.fileActions
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    let reconciled = await Self.waitUntil {
                        guard (try? String(contentsOf: fileURL, encoding: .utf8)) == "new" else { return false }
                        return await (try? store.readContent(
                            rootID: fixture.contextA.rootID,
                            relativePath: relativePath
                        )) == "new"
                    }
                    XCTAssertTrue(reconciled)
                    let finalWaiters = await service.pendingMutationWaiterCountForTesting()
                    XCTAssertEqual(finalWaiters, 0)

                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    fileActionTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    await service.setMutationIOWillBeginHandlerForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let fileActionTask { _ = try? await fileActionTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testReadAutoSelectionThenImmediateManageSelectionAddAndGetPreservesCanonicalOwnership() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = MCPExecutionIgnoringCancellationGate()
                let server = fixture.contextA.window.mcpServer
                let store = fixture.contextA.window.workspaceFileContextStore
                let manager = fixture.networkManager
                let secondRelativePath = "Sources/ImmediateOwnership.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var endpoint: PersistentMCPTestEndpoint?
                _ = try await store.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("ImmediateOwnership")
                )
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "selection-ownership-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "selection-ownership",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    _ = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    _ = try await readTask.value

                    let addTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: [
                                "op": "add",
                                "paths": [secondURL.path],
                                "view": "files"
                            ]
                        )
                    }
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    _ = try await addTask.value

                    let getResponse = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "view": "files"
                        ]
                    )
                    let getText = try Self.toolResultText(getResponse)
                    XCTAssertTrue(getText.contains(fixture.contextA.fileURL.lastPathComponent), getText)
                    XCTAssertTrue(getText.contains(secondURL.lastPathComponent), getText)

                    let canonical = try XCTUnwrap(
                        server.tabContextByConnectionID[createdEndpoint.connectionID]?.selection
                    )
                    XCTAssertEqual(
                        Set(canonical.selectedPaths),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )
                    let mirrored = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)?.selection
                    )
                    XCTAssertEqual(Set(mirrored.selectedPaths), Set(canonical.selectedPaths))

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testWindowIDInjectionAndExplicitValueReachResolvedProviderArguments() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let probe = MCPWindowIDEffectiveArgumentsService(windowID: fixture.contextA.window.windowID)
                ServiceRegistry.unregister(fixture.contextA.catalogService)
                ServiceRegistry.register(probe)
                do {
                    let endpoint = try fixture.endpointA()
                    let cases: [(label: String, arguments: [String: Any], expectedWindowID: Int)] = [
                        (
                            label: "routing window is injected when omitted",
                            arguments: [
                                "marker": "injected",
                                "context_id": fixture.contextA.tabID.uuidString,
                                "_rawJSON": true
                            ],
                            expectedWindowID: fixture.contextA.window.windowID
                        ),
                        (
                            label: "explicit public window_id is preserved",
                            arguments: [
                                "marker": "explicit",
                                "context_id": fixture.contextA.tabID.uuidString,
                                "window_id": fixture.contextB.window.windowID,
                                "_rawJSON": true
                            ],
                            expectedWindowID: fixture.contextB.window.windowID
                        )
                    ]

                    for testCase in cases {
                        let response = try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: testCase.arguments
                        )
                        let payload = try Self.toolResultObject(response)
                        XCTAssertEqual(payload["marker"] as? String, testCase.arguments["marker"] as? String, testCase.label)
                        XCTAssertEqual((payload["window_id"] as? NSNumber)?.intValue, testCase.expectedWindowID, testCase.label)
                    }

                    ServiceRegistry.unregister(probe)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    ServiceRegistry.unregister(probe)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUncooperativeSmallReadDeadlineForceDisconnectsAndCallBeyondCapacityNeverEntersProvider() async throws {
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

                    let second = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.waitForSleeperCount(2)
                    try await operationGate.waitUntilEntered(count: 2)

                    let queuedBeyondCapacity = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: [
                                "path": fixture.contextA.fileURL.path,
                                "context_id": fixture.contextA.tabID.uuidString
                            ]
                        )
                    }
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(2)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(2)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    await Self.assertSocketClosed(first)
                    await Self.assertSocketClosed(second)
                    await Self.assertSocketClosed(queuedBeyondCapacity)
                    let enteredCount = await operationGate.enteredCount()
                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertEqual(enteredCount, MCPToolAdmissionPolicy.smallReadPerWindowLimit)
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

        func testReadFileWatchdogPersistsAttributedTerminalRecordThroughPeerPIDGuard() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let operationGate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let terminalRecordDirectory = fixture.rootURL.appendingPathComponent(
                    "terminal-records",
                    isDirectory: true
                )
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetTerminalRecordDirectoryURLForTesting(terminalRecordDirectory)
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(
                    toolName: MCPWindowToolName.readFile
                ) {
                    await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureAssembly)
                    await operationGate.enterAndWait()
                    return .null
                }
                do {
                    let endpoint = try fixture.endpointA()
                    let call = Task {
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
                    let invocationID = try XCTUnwrap(recorder.snapshot().first {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.readFile
                            && $0.phase == .started
                    }?.invocationID)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                    await Self.assertSocketClosed(call)

                    let didPersist = await Self.waitUntil {
                        (try? FileManager.default.contentsOfDirectory(
                            at: terminalRecordDirectory,
                            includingPropertiesForKeys: nil
                        ).contains { $0.lastPathComponent.hasPrefix("terminal-") }) == true
                    }
                    XCTAssertTrue(didPersist)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let records = try FileManager.default.contentsOfDirectory(
                        at: terminalRecordDirectory,
                        includingPropertiesForKeys: nil
                    ).filter { $0.lastPathComponent.hasPrefix("terminal-") }.map {
                        try decoder.decode(MCPTerminalRecord.self, from: Data(contentsOf: $0))
                    }
                    let record = try XCTUnwrap(records.first {
                        $0.appConnectionID == endpoint.connectionID
                            && $0.reason == "tool_execution_watchdog"
                    })
                    XCTAssertEqual(record.layer, .appAcceptedSocket)
                    XCTAssertEqual(record.peerPID, Int(getpid()))
                    XCTAssertEqual(record.toolName, MCPWindowToolName.readFile)
                    XCTAssertEqual(record.invocationID, invocationID)
                    XCTAssertGreaterThanOrEqual(record.elapsedMilliseconds ?? -1, 35000)
                    XCTAssertEqual(record.handlerPhase, "get_code_structure.assembly")
                    XCTAssertGreaterThanOrEqual(record.handlerPhaseAgeMilliseconds ?? -1, 35000)
                    XCTAssertEqual(record.executionDeadlineMilliseconds, 30000)
                    XCTAssertEqual(record.cleanupGraceMilliseconds, 5000)

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await manager.debugSetTerminalRecordDirectoryURLForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await manager.debugSetTerminalRecordDirectoryURLForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testDetachedCodeStructureTimeoutKeepsConnectionUsableAndDrainsLateProvider() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = ExecutionWatchdogManualClock()
                let provider = MCPCodeStructureSettlementProviderProbe()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let windowID = fixture.contextA.window.windowID
                var firstResponseTask: Task<PersistentMCPTestRPCResponse, Error>?

                EditFlowPerf.resetDebugCaptureForTesting()
                switch EditFlowPerf.beginDebugCapture(label: "code-structure-detached-settlement", maxSamples: 500) {
                case .started:
                    break
                case .busy:
                    return XCTFail("EditFlow capture should start")
                }
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.getCodeStructure) {
                    try await provider.run()
                }

                do {
                    let endpoint = try fixture.endpointA()
                    let arguments: [String: Any] = [
                        "paths": [fixture.contextA.fileURL.path],
                        "context_id": fixture.contextA.tabID.uuidString,
                        "_rawJSON": true
                    ]
                    let detachedCandidate = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.getCodeStructure,
                            arguments: arguments
                        )
                    }
                    firstResponseTask = detachedCandidate
                    try await clock.waitForSleeperCount(1)
                    try await provider.waitUntilEntered(count: 1)

                    // MF1: the second currently legal same-window structure call still enters.
                    let competingResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let competingPayload = try Self.toolResultObject(competingResponse)
                    XCTAssertEqual((competingPayload["ordinal"] as? NSNumber)?.intValue, 2)
                    try await provider.waitUntilEntered(count: 2)
                    let competingSleeperDrained = await Self.waitUntil { await clock.sleeperCount() == 1 }
                    XCTAssertTrue(competingSleeperDrained)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let timeoutResponse = try await detachedCandidate.value
                    firstResponseTask = nil
                    let timeoutPayload = try Self.toolResultObject(timeoutResponse)
                    XCTAssertEqual(timeoutPayload["code"] as? String, "tool_execution_timeout")
                    XCTAssertEqual(timeoutPayload["settlement"] as? String, "detached")
                    XCTAssertEqual(timeoutPayload["cancellation_origin"] as? String, "watchdog_deadline")
                    XCTAssertEqual(timeoutPayload["retryable"] as? Bool, true)
                    let detachSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(detachSleepersDrained)
                    try await clock.advanceWithoutSleepers(by: .seconds(1))
                    let elapsedAfterTimeout = await clock.currentTime()
                    XCTAssertEqual(elapsedAfterTimeout, .seconds(36))

                    let detachedSnapshot = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                    XCTAssertEqual(detachedSnapshot, .init(activeCount: 1, detachedCount: 1))
                    let terminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                    XCTAssertFalse(terminal)

                    // The timed-out request has released its ordinary small-read permit. The one
                    // lingering read-only provider is the documented bounded +1 capacity exception.
                    let limiter = await manager.connectionLimiterSnapshotForTesting(
                        connectionID: endpoint.connectionID,
                        lane: .smallRead
                    )
                    XCTAssertEqual(limiter?.activePermitCount, 0)
                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString
                        ]
                    )
                    let readText = try Self.toolResultText(readResponse)
                    XCTAssertTrue(readText.contains(fixture.contextA.sentinel))
                    let readSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(readSleepersDrained)

                    // Busy is introduced only after the eligible call actually detached.
                    let busyResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let busyPayload = try Self.toolResultObject(busyResponse)
                    XCTAssertEqual(busyPayload["code"] as? String, "tool_execution_structure_settlement_busy")
                    XCTAssertEqual(busyPayload["retryable"] as? Bool, true)
                    XCTAssertEqual((busyPayload["retry_after_ms"] as? NSNumber)?.intValue, 250)
                    XCTAssertEqual(busyPayload["busy_reason"] as? String, "detached_settlement_in_progress")
                    XCTAssertEqual(busyPayload["settlement"] as? String, "busy")
                    XCTAssertTrue((busyPayload["error"] as? String)?.contains("prior timed-out") == true)
                    let enteredCountBeforeDrain = await provider.enteredCount()
                    XCTAssertEqual(enteredCountBeforeDrain, 2)

                    let detachEvents = recorder.snapshot().filter {
                        $0.connectionID == endpoint.connectionID
                            && $0.toolName == MCPWindowToolName.getCodeStructure
                            && $0.phase == .detachedForSettlement
                    }
                    XCTAssertEqual(detachEvents.count, 1)
                    let detachedEvent = try XCTUnwrap(detachEvents.first)
                    XCTAssertTrue(detachedEvent.isAlwaysEmitted)
                    XCTAssertEqual(detachedEvent.cleanupDisposition, .detachAndSettle)
                    XCTAssertEqual(detachedEvent.cancellationOrigin, .watchdogDeadline)
                    XCTAssertEqual(detachedEvent.settlement, "detached")
                    XCTAssertTrue(detachedEvent.description.contains("cancellation_origin=watchdog_deadline"))
                    XCTAssertTrue(detachedEvent.description.contains("settlement=detached"))
                    XCTAssertFalse(recorder.snapshot().contains {
                        $0.invocationID == detachedEvent.invocationID && $0.phase == .handlerCompleted
                    })

                    let responseReadyCountBeforeLateSettlement = EditFlowPerf.debugCaptureSnapshot(finish: false)
                        .lifecycleEvents
                        .count { $0.eventName == "MCP.ToolCall.HandlerResultReady" }

                    await provider.releaseFirst()
                    await manager.debugAwaitCodeStructureSettlementDrain(windowID: windowID)
                    let lateTraceArrived = await Self.waitUntil {
                        recorder.snapshot().contains {
                            $0.invocationID == detachedEvent.invocationID && $0.phase == .detachedSettled
                        }
                    }
                    XCTAssertTrue(lateTraceArrived)
                    let ownershipStateArrived = await Self.waitUntil {
                        EditFlowPerf.debugCaptureSnapshot(finish: false).lifecycleEvents.contains {
                            $0.eventName == "MCP.ToolCall.PublicationOwnershipState"
                                && $0.sanitizedDimensions.contains("tool=get_code_structure")
                                && $0.sanitizedDimensions.contains("outcome=detached_settled")
                                && $0.sanitizedDimensions.contains("providerActive=false")
                                && $0.sanitizedDimensions.contains("networkScopeActive=false")
                                && $0.sanitizedDimensions.contains("permitActive=false")
                                && $0.sanitizedDimensions.contains("publicationPending=false")
                        }
                    }
                    XCTAssertTrue(ownershipStateArrived)

                    let finalEvents = recorder.snapshot().filter { $0.invocationID == detachedEvent.invocationID }
                    let settledEvent = try XCTUnwrap(finalEvents.first { $0.phase == .detachedSettled })
                    XCTAssertTrue(settledEvent.isAlwaysEmitted)
                    XCTAssertEqual(settledEvent.cancellationOutcome, "success")
                    XCTAssertEqual(settledEvent.cancellationOrigin, .watchdogDeadline)
                    XCTAssertEqual(settledEvent.settlement, "detached")
                    XCTAssertFalse(finalEvents.contains { $0.phase == .handlerCompleted })

                    let lateCapture = EditFlowPerf.debugCaptureSnapshot(finish: false)
                    XCTAssertEqual(
                        lateCapture.lifecycleEvents.count { $0.eventName == "MCP.ToolCall.HandlerResultReady" },
                        responseReadyCountBeforeLateSettlement,
                        "Late provider settlement must not publish a handler-result-ready companion"
                    )
                    XCTAssertTrue(lateCapture.lifecycleEvents.contains {
                        $0.eventName == "MCP.ToolCall.ResolvedProviderEnded"
                            && $0.sanitizedDimensions.contains("tool=get_code_structure")
                            && $0.sanitizedDimensions.contains("outcome=detached_settled_success")
                    })
                    XCTAssertTrue(lateCapture.lifecycleEvents.contains {
                        $0.eventName == "MCP.ToolCall.PublicationOwnershipState"
                            && $0.sanitizedDimensions.contains("tool=get_code_structure")
                            && $0.sanitizedDimensions.contains("outcome=detached_settled")
                            && $0.sanitizedDimensions.contains("providerActive=false")
                            && $0.sanitizedDimensions.contains("networkScopeActive=false")
                            && $0.sanitizedDimensions.contains("permitActive=false")
                            && $0.sanitizedDimensions.contains("publicationPending=false")
                    })
                    let drainedSnapshot = await manager.debugCodeStructureSettlementSnapshot(windowID: windowID)
                    XCTAssertEqual(
                        drainedSnapshot,
                        .init(activeCount: 0, detachedCount: 0)
                    )
                    let sleeperCountAfterDrain = await clock.sleeperCount()
                    XCTAssertEqual(sleeperCountAfterDrain, 0)

                    // A fresh generation is admitted after drain and completes normally.
                    let postDrainResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getCodeStructure,
                        arguments: arguments
                    )
                    let postDrainPayload = try Self.toolResultObject(postDrainResponse)
                    XCTAssertEqual((postDrainPayload["ordinal"] as? NSNumber)?.intValue, 3)
                    let finalSleepersDrained = await Self.waitUntil { await clock.sleeperCount() == 0 }
                    XCTAssertTrue(finalSleepersDrained)

                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await provider.releaseFirst()
                    firstResponseTask?.cancel()
                    if let firstResponseTask { _ = try? await firstResponseTask.value }
                    _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
                    EditFlowPerf.resetDebugCaptureForTesting()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.getCodeStructure,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func waitUntil(
            timeout: Duration = .seconds(10),
            condition: () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
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

        private static func toolResultObject(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let text = try toolResultText(response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    @MainActor
    private final class MCPAppSettingsServiceScope {
        private let service: AppSettingsMCPService
        private let ownsService: Bool
        private let baselineServiceIDs: [ObjectIdentifier]
        private let baselineAvailable: Bool
        private let baselineDisabled: Bool
        private var restored = false

        private init() {
            let existingServices = ServiceRegistry.services.compactMap { $0 as? AppSettingsMCPService }
            service = existingServices.first ?? AppSettingsMCPService()
            ownsService = existingServices.isEmpty
            baselineServiceIDs = existingServices.map { ObjectIdentifier($0) }
            baselineAvailable = ToolAvailabilityStore.shared.toolSummaries.contains {
                $0.name == MCPGlobalToolName.appSettings
            }
            baselineDisabled = ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings)
        }

        static func install() async throws -> MCPAppSettingsServiceScope {
            let scope = MCPAppSettingsServiceScope()
            do {
                if scope.baselineDisabled {
                    await ToolAvailabilityStore.shared.toggle(MCPGlobalToolName.appSettings, enabled: true)
                }
                if scope.ownsService {
                    ServiceRegistry.register(scope.service)
                }
                try await scope.waitUntilReady()
                XCTAssertTrue(ToolAvailabilityStore.shared.isEnabled(MCPGlobalToolName.appSettings))
                return scope
            } catch {
                await scope.restore()
                throw error
            }
        }

        func restore() async {
            guard !restored else { return }
            restored = true

            if ownsService {
                ServiceRegistry.unregister(service)
            }
            if !baselineAvailable {
                ToolAvailabilityStore.shared.unregisterTools([MCPGlobalToolName.appSettings])
            }
            let isDisabled = ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings)
            if isDisabled != baselineDisabled {
                await ToolAvailabilityStore.shared.toggle(
                    MCPGlobalToolName.appSettings,
                    enabled: !baselineDisabled
                )
            }
        }

        func assertRestored(file: StaticString = #filePath, line: UInt = #line) {
            let serviceIDs = ServiceRegistry.services
                .compactMap { $0 as? AppSettingsMCPService }
                .map { ObjectIdentifier($0) }
            XCTAssertEqual(serviceIDs, baselineServiceIDs, file: file, line: line)
            XCTAssertEqual(
                ToolAvailabilityStore.shared.toolSummaries.contains {
                    $0.name == MCPGlobalToolName.appSettings
                },
                baselineAvailable,
                file: file,
                line: line
            )
            XCTAssertEqual(
                ToolAvailabilityStore.shared.disabledTools.contains(MCPGlobalToolName.appSettings),
                baselineDisabled,
                file: file,
                line: line
            )
        }

        private func waitUntilReady() async throws {
            for _ in 0 ..< 1000 {
                let isRegistered = ServiceRegistry.services.contains {
                    ($0 as AnyObject) === (service as AnyObject)
                }
                let isAvailable = ToolAvailabilityStore.shared.toolSummaries.contains {
                    $0.name == MCPGlobalToolName.appSettings
                }
                if isRegistered, isAvailable {
                    return
                }
                await Task.yield()
            }
            throw MCPExecutionWatchdogIntegrationFixtureError.toolAvailabilityDidNotPublish(
                MCPGlobalToolName.appSettings
            )
        }
    }

    private final class MCPWindowIDEffectiveArgumentsService: WindowScopedService {
        let windowID: Int

        init(windowID: Int) {
            self.windowID = windowID
        }

        var tools: [RepoPromptApp.Tool] {
            get async {
                [
                    RepoPromptApp.Tool(
                        name: MCPWindowToolName.readFile,
                        description: "Test probe for resolved provider arguments.",
                        inputSchema: .object(
                            properties: [
                                "marker": .string(description: "Scenario marker."),
                                "window_id": .integer(description: "Effective public window identifier.")
                            ],
                            required: ["marker"]
                        ),
                        returnsValue: { args in .object(args) }
                    )
                ]
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

    /// Cooperative cancel probe: thin wrapper over shared `TestCancellationGate`.
    private actor MCPExecutionCooperativeCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private let gate = TestCancellationGate(name: "MCP execution cooperative cancellation gate")

        func enterAndWait() async throws {
            try await gate.waitUntilCancelled()
        }

        func waitUntilEntered(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let entered = await gate.waitUntilEntered(
                timeout: TestFenceDefaults.timeInterval(timeout),
                failOnTimeout: false
            )
            guard entered else {
                throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateDidNotEnter
            }
        }

        func waitUntilCancellationObserved(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let timeoutInterval = TestFenceDefaults.timeInterval(timeout)
            do {
                try await AsyncTestWait.waitUntil(
                    "MCP cooperative gate cancellation observed",
                    timeout: timeoutInterval
                ) {
                    self.gate.cancellationCount > 0
                }
            } catch {
                throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateCancellationNotObserved
            }
        }

        func observedCancellationCount() async -> Int {
            gate.cancellationCount
        }

        func cancelForCleanup() async {
            gate.forceCancel()
        }
    }

    private actor MCPPostProviderAdmissionProbe {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var connectionIDs: [UUID] = []

        func record(connectionID: UUID?) -> Value {
            if let connectionID {
                connectionIDs.append(connectionID)
            }
            return .object(["status": .string("ok")])
        }

        func waitUntilEntered(
            connectionID: UUID,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !connectionIDs.contains(connectionID) {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: 1,
                        actual: connectionIDs.count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private actor MCPCodeStructureSettlementProviderProbe {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var count = 0
        private var firstReleased = false
        private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

        func run() async throws -> Value {
            count += 1
            let ordinal = count
            if ordinal == 1, !firstReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
            return .object(["ordinal": .int(ordinal)])
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

        func releaseFirst() {
            firstReleased = true
            firstReleaseWaiters.forEach { $0.resume() }
            firstReleaseWaiters.removeAll()
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
        case cooperativeGateCancellationNotObserved
        case cooperativeGateDidNotEnter
        case gateDidNotEnter(expected: Int, actual: Int)
        case toolAvailabilityDidNotPublish(String)
    }

#endif
