import Foundation
import JSONSchema
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
                                "content": "struct CreatedAfterWatchdog {}\n"
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
                    content: "struct ImmediateOwnership {}\n"
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

        var tools: [RepoPrompt.Tool] {
            get async {
                [
                    RepoPrompt.Tool(
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

    private actor MCPExecutionCooperativeCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var entered = false
        private var cancellationCount = 0
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

        func waitUntilCancellationObserved(
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while cancellationCount == 0 {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.cooperativeGateCancellationNotObserved
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func observedCancellationCount() -> Int {
            cancellationCount
        }

        func cancelForCleanup() {
            cancel()
        }

        private func cancel() {
            cancellationCount += 1
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
        case cooperativeGateCancellationNotObserved
        case cooperativeGateDidNotEnter
        case gateDidNotEnter(expected: Int, actual: Int)
        case toolAvailabilityDidNotPublish(String)
    }

#endif
