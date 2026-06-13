import Darwin
import Foundation
@testable import RepoPrompt
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class PersistentMCPResponseDeliveryTests: XCTestCase {
    func testProxyHalfCloseDrainsResponseAfterFormerGraceCheckpoint() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
        XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
        defer {
            (sockets + stdinPipe + stdoutPipe).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let poller = ManualBridgeSocketPoller()
        let drainClock = ManualBridgeDrainClock()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await poller.next() },
                    drainClock: { drainClock.now() },
                    onStdinClosed: {
                        drainClock.advance(by: 2)
                        await poller.markStdinClosed()
                    }
                )
                await poller.markBridgeCompleted()
            } catch {
                await poller.markBridgeCompleted()
                throw error
            }
        }

        let requestFrame = request(id: 401)
        try Self.writeAll(requestFrame, to: stdinPipe[1])
        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1
        let forwardedRequest = try await Task.detached {
            try Self.readLine(from: sockets[1])
        }.value
        XCTAssertEqual(forwardedRequest, requestFrame)
        let observedStdinClose = await poller.waitUntilStdinClosed()
        XCTAssertTrue(observedStdinClose)
        XCTAssertGreaterThan(drainClock.now(), 1)

        let reachedInitialWait = await poller.waitUntilWaiting(count: 1)
        XCTAssertTrue(reachedInitialWait)
        await poller.resumeNext(.timedOut)
        let reachedBeyondFormerGraceWait = await poller.waitUntilWaiting(count: 2)
        XCTAssertTrue(
            reachedBeyondFormerGraceWait,
            "The bridge exited after the former one-second drain grace instead of waiting for the active response"
        )

        let responseFrame = response(id: 401)
        try Self.writeAll(responseFrame, to: sockets[1])
        await poller.resumeNext(.events(Int16(POLLIN)))
        try await bridgeTask.value

        let deliveredResponse = try Self.readLine(from: stdoutPipe[0])
        XCTAssertEqual(deliveredResponse, responseFrame)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertNil(snapshot.terminalReason)
    }

    func testProxyHalfClosePeriodicallyReportsBlockingDrainCounters() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var drainLogPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
        XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
        XCTAssertEqual(Darwin.pipe(&drainLogPipe), 0)
        defer {
            (sockets + stdinPipe + stdoutPipe + drainLogPipe).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let poller = ManualBridgeSocketPoller()
        let drainClock = ManualBridgeDrainClock()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await poller.next() },
                    drainClock: { drainClock.now() },
                    drainVisibilityInterval: 1,
                    drainLogDescriptor: drainLogPipe[1],
                    onStdinClosed: {
                        await poller.markStdinClosed()
                    }
                )
                await poller.markBridgeCompleted()
            } catch {
                await poller.markBridgeCompleted()
                throw error
            }
        }

        let requestFrame = request(id: 402)
        try Self.writeAll(requestFrame, to: stdinPipe[1])
        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1
        let forwardedRequest = try await Task.detached {
            try Self.readLine(from: sockets[1])
        }.value
        XCTAssertEqual(forwardedRequest, requestFrame)
        let observedStdinClose = await poller.waitUntilStdinClosed()
        XCTAssertTrue(observedStdinClose)

        let reachedInitialWait = await poller.waitUntilWaiting(count: 1)
        XCTAssertTrue(reachedInitialWait)
        await poller.resumeNext(.timedOut)
        let reachedSecondWait = await poller.waitUntilWaiting(count: 2)
        XCTAssertTrue(reachedSecondWait)

        drainClock.advance(by: 0.5)
        await poller.resumeNext(.timedOut)
        let reachedThirdWait = await poller.waitUntilWaiting(count: 3)
        XCTAssertTrue(reachedThirdWait)

        drainClock.advance(by: 0.5)
        await poller.resumeNext(.timedOut)
        let reachedFourthWait = await poller.waitUntilWaiting(count: 4)
        XCTAssertTrue(reachedFourthWait)

        let responseFrame = response(id: 402)
        try Self.writeAll(responseFrame, to: sockets[1])
        await poller.resumeNext(.events(Int16(POLLIN)))
        try await bridgeTask.value

        Self.closeIfOpen(drainLogPipe[1])
        drainLogPipe[1] = -1
        let logData = try Self.readToEOF(from: drainLogPipe[0])
        let log = try XCTUnwrap(String(data: logData, encoding: .utf8))
        XCTAssertEqual(log.components(separatedBy: "[MCPBridgeDrain] waiting").count - 1, 2, log)
        XCTAssertTrue(log.contains("active_requests=1"), log)
        XCTAssertTrue(log.contains("pending_transactions=0"), log)
        XCTAssertTrue(log.contains("partial_bytes=0"), log)
        XCTAssertTrue(log.contains("response_in_delivery=0"), log)
    }

    @MainActor
    func testExecutionWatchdogTransportAbortTerminatesBridgeWithoutReconnectAndMapsToNonzeroStdioExit() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let clock = ExecutionWatchdogManualClock()
                let operationGate = WatchdogIgnoringCancellationGate()
                let traceRecorder = WatchdogExecutionTraceRecorder()
                let clientName = "bridge-watchdog-terminal-\(UUID().uuidString)"
                var harness: ExecutionWatchdogBridgeHarness?
                var toolCall: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { traceRecorder.append($0) }
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
                    let createdHarness = try await ExecutionWatchdogBridgeHarness.make(
                        networkManager: manager,
                        clientName: clientName
                    )
                    harness = createdHarness
                    let activeToolCall = Task {
                        try await createdHarness.callTool(
                            name: MCPGlobalToolName.manageWorkspaces,
                            arguments: [
                                "action": "switch",
                                "workspace": fixture.contextA.workspaceID.uuidString,
                                "window_id": fixture.contextA.window.windowID
                            ]
                        )
                    }
                    toolCall = activeToolCall
                    try await clock.waitForSleeperCount(1)
                    try await operationGate.waitUntilEntered()

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadline)
                    try await clock.waitForSleeperCount(1)
                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

                    let bridgeResult = try await createdHarness.waitForBridgeResult(timeout: .seconds(10))
                    guard case let .failure(rawBridgeError) = bridgeResult,
                          let bridgeError = rawBridgeError as? JSONRPCBridgeLedgerError
                    else {
                        XCTFail("Expected execution watchdog to terminate the bridge with a ledger error")
                        throw WatchdogBridgeFixtureError.unexpectedBridgeResult
                    }

                    do {
                        _ = try await activeToolCall.value
                        XCTFail("Expected watchdog bridge termination to close the stdio client")
                    } catch PersistentMCPTestSocketClient.ClientError.closed {
                        // Expected: the bridge-owned stdio descriptor closed on terminal exit.
                    }
                    toolCall = nil

                    let terminalSnapshot = await createdHarness.ledger.snapshot()
                    let terminalReason = try XCTUnwrap(terminalSnapshot.terminalReason)
                    XCTAssertTrue(
                        ["socket_eof_with_outstanding_work", "socket_hangup_with_outstanding_work"]
                            .contains(terminalReason),
                        terminalReason
                    )
                    XCTAssertEqual(bridgeError, .terminal(terminalReason))
                    XCTAssertEqual(terminalSnapshot.activeRequestCount, 1)
                    XCTAssertFalse(terminalSnapshot.canReconnect)
                    XCTAssertEqual(createdHarness.traces.count(phase: "terminal_eof"), 1)
                    let watchdogMarkedTerminal = await manager.debugIsExecutionWatchdogTerminal(
                        connectionID: createdHarness.connectionID
                    )
                    let enteredCount = await operationGate.enteredCount()
                    XCTAssertTrue(watchdogMarkedTerminal)
                    XCTAssertEqual(enteredCount, 1)

                    let watchdogEvents = traceRecorder.snapshot().filter {
                        $0.connectionID == createdHarness.connectionID
                            && $0.toolName == MCPGlobalToolName.manageWorkspaces
                    }
                    XCTAssertTrue(watchdogEvents.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertTrue(watchdogEvents.contains { $0.phase == .connectionForceDisconnectRequested })

                    // The XCTest target imports the executable module in-process, so invoking
                    // handleRuntimeError would terminate the test runner. The production mapping
                    // reached after this real watchdog→transport→bridge failure is asserted here;
                    // the pending request's `.closed` result above covers observable stdio EOF.
                    XCTAssertEqual(
                        mcpCLIExitCode(for: .connectionFailed(underlying: bridgeError)),
                        .connectionFailed
                    )
                    XCTAssertNotEqual(MCPCLIExitCode.connectionFailed.rawValue, MCPCLIExitCode.ok.rawValue)

                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await createdHarness.cleanup()
                    harness = nil
                    await fixture.cleanup()
                } catch {
                    toolCall?.cancel()
                    if let toolCall {
                        _ = try? await toolCall.value
                    }
                    await operationGate.release()
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPGlobalToolName.manageWorkspaces,
                        operation: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let harness {
                        await harness.cleanup()
                    } else {
                        await manager.clearClientConnectionPolicy(for: clientName)
                        await manager.debugClearPersistedRoutingState(for: clientName)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        #else
            throw XCTSkip("Execution watchdog socket integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testPendingResponseTransactionHalfCloseExpiresDrainDeadlineExactlyOnce() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var drainLogPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
        XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
        XCTAssertEqual(Darwin.pipe(&drainLogPipe), 0)
        defer {
            (sockets + stdinPipe + stdoutPipe + drainLogPipe).forEach(Self.closeIfOpen)
        }

        let traces = BridgeTraceRecorder()
        let ledger = JSONRPCBridgeLedger(traceSink: { traces.append($0) })
        _ = try await ledger.beginConnection()
        let preparedRequest = try await ledger.prepare(
            frame: request(id: 404),
            direction: .clientToServer
        )
        try await ledger.commit(preparedRequest)
        _ = try await ledger.prepare(
            frame: response(id: 404),
            direction: .serverToClient
        )
        let pendingSnapshot = await ledger.snapshot()
        XCTAssertEqual(pendingSnapshot.activeRequestCount, 1)
        XCTAssertEqual(pendingSnapshot.responseInDeliveryCount, 1)
        XCTAssertEqual(pendingSnapshot.pendingTransactionCount, 1)

        let poller = ManualBridgeSocketPoller()
        let drainClock = ManualBridgeDrainClock()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await poller.next() },
                    drainClock: { drainClock.now() },
                    drainDeadline: 1,
                    drainLogDescriptor: drainLogPipe[1],
                    onStdinClosed: {
                        drainClock.advance(by: 2)
                        await poller.markStdinClosed()
                    }
                )
                await poller.markBridgeCompleted()
            } catch {
                await poller.markBridgeCompleted()
                throw error
            }
        }

        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1
        let observedStdinClose = await poller.waitUntilStdinClosed()
        XCTAssertTrue(observedStdinClose)
        let reachedDrainWait = await poller.waitUntilWaiting(count: 1)
        XCTAssertTrue(reachedDrainWait)
        await poller.resumeNext(.timedOut)

        var observedBridgeError: JSONRPCBridgeLedgerError?
        do {
            try await bridgeTask.value
            XCTFail("Expected pending response transaction to expire the bridge drain deadline")
        } catch let error as JSONRPCBridgeLedgerError {
            observedBridgeError = error
        }
        let bridgeError = try XCTUnwrap(observedBridgeError)
        let deadlineReason = JSONRPCBridgeLedger.postStdinHalfCloseDrainDeadlineExceededReason
        XCTAssertEqual(bridgeError, .terminal(deadlineReason))

        Self.closeIfOpen(drainLogPipe[1])
        drainLogPipe[1] = -1
        let logData = try Self.readToEOF(from: drainLogPipe[0])
        let log = try XCTUnwrap(String(data: logData, encoding: .utf8))
        XCTAssertTrue(log.contains("[MCPBridgeDrain] deadline_exceeded"), log)
        XCTAssertTrue(log.contains("deadline=1.000s"), log)
        XCTAssertTrue(log.contains("active_requests=1"), log)
        XCTAssertTrue(log.contains("pending_transactions=1"), log)
        XCTAssertTrue(log.contains("partial_bytes=0"), log)
        XCTAssertTrue(log.contains("response_in_delivery=1"), log)
        XCTAssertTrue(log.contains("terminalized_reason=\(deadlineReason)"), log)

        let terminalSnapshot = await ledger.snapshot()
        XCTAssertEqual(terminalSnapshot.terminalReason, deadlineReason)
        XCTAssertEqual(terminalSnapshot.pendingTransactionCount, 1)
        XCTAssertFalse(terminalSnapshot.canReconnect)
        XCTAssertEqual(
            traces.count(phase: "post_stdin_half_close_drain_deadline_exceeded"),
            1
        )
        let repeatedTerminalReason = await ledger.terminalizePostStdinHalfCloseDrainDeadline()
        XCTAssertEqual(repeatedTerminalReason, deadlineReason)
        XCTAssertEqual(
            traces.count(phase: "post_stdin_half_close_drain_deadline_exceeded"),
            1
        )
        let deadlineFailureWasTerminal = await ledger.recordConnectionFailure("bridge_drain_deadline")
        XCTAssertTrue(deadlineFailureWasTerminal)
        XCTAssertEqual(
            mcpCLIExitCode(for: .connectionFailed(underlying: bridgeError)),
            .connectionFailed
        )
        XCTAssertGreaterThan(
            MCPTimeoutPolicy.postStdinHalfCloseBridgeDrainDeadlineSeconds,
            MCPTimeoutPolicy.workspaceSwitchToolExecutionDeadlineSeconds
        )

        let freshLedger = JSONRPCBridgeLedger()
        let freshGeneration = try await freshLedger.beginConnection()
        XCTAssertEqual(freshGeneration, 1)
        let freshSnapshot = await freshLedger.snapshot()
        XCTAssertTrue(freshSnapshot.canReconnect)
    }

    func testDrainDeadlineRemainsBoundedWhenDiagnosticPipeIsFullAndUnread() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var drainLogPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
        XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
        XCTAssertEqual(Darwin.pipe(&drainLogPipe), 0)
        defer {
            (sockets + stdinPipe + stdoutPipe + drainLogPipe).forEach(Self.closeIfOpen)
        }

        let traces = BridgeTraceRecorder()
        let drainLogWriteFD = drainLogPipe[1]
        let ledger = JSONRPCBridgeLedger(traceSink: { event in
            traces.append(event)
            MCPResponseDeliveryTracer.emit(event, to: drainLogWriteFD)
        })
        _ = try await ledger.beginConnection()
        let preparedRequest = try await ledger.prepare(
            frame: request(id: 405),
            direction: .clientToServer
        )
        try await ledger.commit(preparedRequest)
        _ = try await ledger.prepare(
            frame: response(id: 405),
            direction: .serverToClient
        )
        try Self.fillPipeToCapacity(drainLogPipe[1])

        let poller = ManualBridgeSocketPoller()
        let drainClock = ManualBridgeDrainClock()
        let resultBox = BridgeTaskResultBox()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await poller.next() },
                    drainClock: { drainClock.now() },
                    drainDeadline: 1,
                    drainVisibilityInterval: 0.1,
                    drainLogDescriptor: drainLogPipe[1],
                    onStdinClosed: {
                        drainClock.advance(by: 2)
                        await poller.markStdinClosed()
                    }
                )
                resultBox.store(.success(()))
            } catch {
                resultBox.store(.failure(error))
            }
            await poller.markBridgeCompleted()
        }

        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1
        let observedStdinClose = await poller.waitUntilStdinClosed()
        let reachedDrainWait = await poller.waitUntilWaiting(count: 1)
        XCTAssertTrue(observedStdinClose)
        XCTAssertTrue(reachedDrainWait)
        await poller.resumeNext(.timedOut)

        let completedWhilePipeRemainedFull = await resultBox.waitUntilStored(timeout: .seconds(1))
        if !completedWhilePipeRemainedFull {
            Self.closeIfOpen(drainLogPipe[0])
            drainLogPipe[0] = -1
        }
        await bridgeTask.value
        XCTAssertTrue(
            completedWhilePipeRemainedFull,
            "Drain deadline diagnostics blocked on a full unread pipe"
        )

        guard case let .failure(rawError) = resultBox.load(),
              let bridgeError = rawError as? JSONRPCBridgeLedgerError
        else {
            XCTFail("Expected the full-pipe deadline path to terminate with a ledger error")
            return
        }
        let deadlineReason = JSONRPCBridgeLedger.postStdinHalfCloseDrainDeadlineExceededReason
        XCTAssertEqual(bridgeError, .terminal(deadlineReason))
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, deadlineReason)
        XCTAssertFalse(snapshot.canReconnect)
        XCTAssertEqual(
            traces.count(phase: "post_stdin_half_close_drain_deadline_exceeded"),
            1
        )
    }

    func testFiveIndependentCallsDeliverExactlyFiveMatchingResponses() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        for id in 101 ... 105 {
            try await deliver(request(id: id), direction: .clientToServer, ledger: ledger, writes: writes)
        }
        for id in [105, 103, 101, 104, 102] {
            try await deliver(response(id: id), direction: .serverToClient, ledger: ledger, writes: writes)
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.recentCompletionCount, 5)
        let writtenFrameCount = await writes.frames.count
        let deliveredResponseIDs = await writes.responseIDs
        XCTAssertEqual(writtenFrameCount, 10)
        XCTAssertEqual(Set(deliveredResponseIDs), Set(101 ... 105))
    }

    func testExactIDStdoutFaultTerminatesConnectionWithoutSelectiveDropContinuation() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        for id in 101 ... 105 {
            try await deliver(request(id: id), direction: .clientToServer, ledger: ledger, writes: writes)
        }

        try await deliver(response(id: 101), direction: .serverToClient, ledger: ledger, writes: writes)
        let fault = JSONRPCBridgeFaultRule(direction: .serverToClient, id: .number(102))
        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 102),
                direction: .serverToClient,
                ledger: ledger,
                faultRule: fault
            ) { frame in
                await writes.record(frame)
            }
            XCTFail("Expected exact-ID injected write failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .injectedFault(.serverToClient, .number(102)))
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, "fault_injected_fail_destination_write")
        XCTAssertFalse(snapshot.canReconnect)
        let deliveredResponseIDs = await writes.responseIDs
        XCTAssertEqual(deliveredResponseIDs, [101])

        do {
            try await deliver(response(id: 103), direction: .serverToClient, ledger: ledger, writes: writes)
            XCTFail("A terminal session must reject later sibling responses")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .terminal("fault_injected_fail_destination_write"))
        }
    }

    func testFaultRuleCanConstrainMethodAndToolWithoutPayloadMatching() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        try await deliver(request(id: 201, tool: "read_file"), direction: .clientToServer, ledger: ledger, writes: writes)
        let matching = JSONRPCBridgeFaultRule(
            direction: .serverToClient,
            id: .number(201),
            method: "tools/call",
            tool: "read_file"
        )
        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 201),
                direction: .serverToClient,
                ledger: ledger,
                faultRule: matching
            ) { frame in
                await writes.record(frame)
            }
            XCTFail("Expected constrained fault to match correlated request metadata")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .injectedFault(.serverToClient, .number(201)))
        }
    }

    func testIDReuseAfterResponseBytesWriteBeforeLedgerCommitIsAccepted() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let responseWriteGate = AsyncGate()
        let writes = WriteRecorder()

        try await deliver(request(id: 250), direction: .clientToServer, ledger: ledger, writes: writes)
        let responseTask = Task {
            try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 250),
                direction: .serverToClient,
                ledger: ledger
            ) { frame in
                await writes.record(frame)
                await responseWriteGate.markEnteredAndWait()
            }
        }

        await responseWriteGate.waitUntilEntered()
        try await deliver(request(id: 250, tool: "search"), direction: .clientToServer, ledger: ledger, writes: writes)
        await responseWriteGate.release()
        _ = try await responseTask.value

        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        try await deliver(response(id: 250), direction: .serverToClient, ledger: ledger, writes: writes)
        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
    }

    func testImmediateResponseWhileRequestWriterIsHeldDoesNotBecomeUnknown() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let gate = AsyncGate()
        let writes = WriteRecorder()

        let requestTask = Task {
            try await JSONRPCBridgeDelivery.forward(
                frame: request(id: 301),
                direction: .clientToServer,
                ledger: ledger
            ) { frame in
                await gate.markEnteredAndWait()
                await writes.record(frame)
            }
        }

        await gate.waitUntilEntered()
        try await deliver(response(id: 301), direction: .serverToClient, ledger: ledger, writes: writes)
        await gate.release()
        _ = try await requestTask.value

        let activeRequestCount = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeRequestCount, 0)
    }
}

private final class ManualBridgeDrainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private actor ManualBridgeSocketPoller {
    private var waitingCount = 0
    private var queuedResults: [BridgeSocketPollResult] = []
    private var resultContinuation: CheckedContinuation<BridgeSocketPollResult, Error>?
    private var pendingPollCancelled = false
    private var stdinClosed = false
    private var bridgeCompleted = false
    private var stdinClosedWaiters: [CheckedContinuation<Bool, Never>] = []
    private var waitingCountWaiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    func next() async throws -> BridgeSocketPollResult {
        waitingCount += 1
        resumeWaitingCountWaiters()
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if pendingPollCancelled {
                    pendingPollCancelled = false
                    continuation.resume(throwing: CancellationError())
                } else {
                    resultContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPendingPoll() }
        }
    }

    func resumeNext(_ result: BridgeSocketPollResult) {
        if let resultContinuation {
            self.resultContinuation = nil
            resultContinuation.resume(returning: result)
        } else {
            queuedResults.append(result)
        }
    }

    func markStdinClosed() {
        stdinClosed = true
        let waiters = stdinClosedWaiters
        stdinClosedWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitUntilStdinClosed() async -> Bool {
        if stdinClosed { return true }
        if bridgeCompleted { return false }
        return await withCheckedContinuation { stdinClosedWaiters.append($0) }
    }

    func waitUntilWaiting(count: Int) async -> Bool {
        if waitingCount >= count { return true }
        if bridgeCompleted { return false }
        return await withCheckedContinuation { continuation in
            waitingCountWaiters.append((count, continuation))
        }
    }

    func markBridgeCompleted() {
        bridgeCompleted = true
        cancelPendingPoll()
        let closeWaiters = stdinClosedWaiters
        stdinClosedWaiters.removeAll()
        closeWaiters.forEach { $0.resume(returning: false) }
        resumeWaitingCountWaiters()
    }

    private func cancelPendingPoll() {
        guard let resultContinuation else {
            pendingPollCancelled = true
            return
        }
        self.resultContinuation = nil
        resultContinuation.resume(throwing: CancellationError())
    }

    private func resumeWaitingCountWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
        for waiter in waitingCountWaiters {
            if waitingCount >= waiter.count {
                waiter.continuation.resume(returning: true)
            } else if bridgeCompleted {
                waiter.continuation.resume(returning: false)
            } else {
                pending.append(waiter)
            }
        }
        waitingCountWaiters = pending
    }
}

private final class BridgeTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MCPResponseDeliveryTraceEvent] = []

    func append(_ event: MCPResponseDeliveryTraceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func count(phase: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count { $0.phase == phase }
    }
}

private final class BridgeTaskResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func waitUntilStored(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while load() == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return load() != nil
    }
}

#if DEBUG
    private final class WatchdogExecutionTraceRecorder: @unchecked Sendable {
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

    private actor WatchdogIgnoringCancellationGate {
        private var count = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            count += 1
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered(timeout: Duration = .seconds(10)) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while count == 0 {
                guard clock.now < deadline else {
                    throw WatchdogBridgeFixtureError.operationDidNotEnter
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

    private final class ExecutionWatchdogBridgeHarness: @unchecked Sendable {
        let connectionID: UUID
        let ledger: JSONRPCBridgeLedger
        let traces: BridgeTraceRecorder

        private let clientName: String
        private let networkManager: ServerNetworkManager
        private let connectionManager: BootstrapSocketConnectionManager
        private let client: PersistentMCPTestSocketClient
        private let startTask: Task<Void, Error>
        private let bridgeTask: Task<Void, Never>
        private let bridgeResult: BridgeTaskResultBox
        private var cleanedUp = false

        private init(
            connectionID: UUID,
            clientName: String,
            networkManager: ServerNetworkManager,
            connectionManager: BootstrapSocketConnectionManager,
            client: PersistentMCPTestSocketClient,
            ledger: JSONRPCBridgeLedger,
            traces: BridgeTraceRecorder,
            startTask: Task<Void, Error>,
            bridgeTask: Task<Void, Never>,
            bridgeResult: BridgeTaskResultBox
        ) {
            self.connectionID = connectionID
            self.clientName = clientName
            self.networkManager = networkManager
            self.connectionManager = connectionManager
            self.client = client
            self.ledger = ledger
            self.traces = traces
            self.startTask = startTask
            self.bridgeTask = bridgeTask
            self.bridgeResult = bridgeResult
        }

        @MainActor
        static func make(
            networkManager: ServerNetworkManager,
            clientName: String
        ) async throws -> ExecutionWatchdogBridgeHarness {
            var sockets = [Int32](repeating: -1, count: 2)
            var stdioSockets = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                throw WatchdogBridgeFixtureError.posix(operation: "app socketpair", code: errno)
            }
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &stdioSockets) == 0 else {
                sockets.forEach(PersistentMCPResponseDeliveryTests.closeIfOpen)
                throw WatchdogBridgeFixtureError.posix(operation: "stdio socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                stdioSockets[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                (sockets + stdioSockets).forEach(PersistentMCPResponseDeliveryTests.closeIfOpen)
                throw WatchdogBridgeFixtureError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }

            let connectionID = UUID()
            let sessionToken = "bridge-watchdog-\(UUID().uuidString)"
            await networkManager.debugClearPersistedRoutingState(for: clientName)
            let connectionManager: BootstrapSocketConnectionManager
            do {
                connectionManager = try BootstrapSocketConnectionManager(
                    connectionID: connectionID,
                    sessionToken: sessionToken,
                    clientPid: Int(getpid()),
                    clientName: clientName,
                    purpose: .agentModeRun,
                    codeMapsDisabled: false,
                    connectedFD: sockets[1],
                    parentManager: networkManager
                )
                sockets[1] = -1
            } catch {
                (sockets + stdioSockets).forEach(PersistentMCPResponseDeliveryTests.closeIfOpen)
                throw error
            }

            await networkManager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connectionManager,
                clientName: clientName,
                sessionToken: sessionToken
            )

            let traces = BridgeTraceRecorder()
            let ledger = JSONRPCBridgeLedger(traceSink: { traces.append($0) })
            _ = try await ledger.beginConnection()
            let bridgeResult = BridgeTaskResultBox()
            let client = PersistentMCPTestSocketClient(fd: stdioSockets[0])
            stdioSockets[0] = -1
            let bridgeSocketFD = sockets[0]
            sockets[0] = -1
            let bridgeStdioFD = stdioSockets[1]
            stdioSockets[1] = -1
            let bridgeTask = Task {
                defer {
                    PersistentMCPResponseDeliveryTests.closeIfOpen(bridgeSocketFD)
                    PersistentMCPResponseDeliveryTests.closeIfOpen(bridgeStdioFD)
                }
                do {
                    try await BootstrapSocketProxy.runBridge(
                        socketFD: bridgeSocketFD,
                        stdinFD: bridgeStdioFD,
                        stdoutFD: bridgeStdioFD,
                        identityCache: ClientIdentityCache(),
                        bridgeLedger: ledger,
                        faultRule: nil
                    )
                    bridgeResult.store(.success(()))
                } catch {
                    bridgeResult.store(.failure(error))
                }
            }
            let startTask = Task {
                try await connectionManager.start { clientInfo in
                    guard clientInfo.name == clientName else { return false }
                    _ = await networkManager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: clientInfo.name
                    )
                    return true
                }
            }
            let harness = ExecutionWatchdogBridgeHarness(
                connectionID: connectionID,
                clientName: clientName,
                networkManager: networkManager,
                connectionManager: connectionManager,
                client: client,
                ledger: ledger,
                traces: traces,
                startTask: startTask,
                bridgeTask: bridgeTask,
                bridgeResult: bridgeResult
            )

            do {
                _ = try await client.request(
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": clientName,
                            "version": "bridge-watchdog-terminal-test"
                        ]
                    ]
                )
                try await startTask.value
                try client.sendNotification(method: "notifications/initialized", params: [:])
                return harness
            } catch {
                await harness.cleanup()
                throw error
            }
        }

        func callTool(
            name: String,
            arguments: [String: Any]
        ) async throws -> PersistentMCPTestRPCResponse {
            try await client.request(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ]
            )
        }

        func waitForBridgeResult(timeout: Duration) async throws -> Result<Void, Error> {
            guard await bridgeResult.waitUntilStored(timeout: timeout),
                  let result = bridgeResult.load()
            else {
                throw WatchdogBridgeFixtureError.bridgeDidNotTerminate
            }
            return result
        }

        @MainActor
        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            client.close()
            bridgeTask.cancel()
            startTask.cancel()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            await networkManager.clearClientConnectionPolicy(for: clientName)
            await networkManager.debugClearPersistedRoutingState(for: clientName)
            _ = try? await startTask.value
            _ = await bridgeResult.waitUntilStored(timeout: .seconds(2))
        }
    }

    private enum WatchdogBridgeFixtureError: Error {
        case bridgeDidNotTerminate
        case operationDidNotEnter
        case posix(operation: String, code: Int32)
        case unexpectedBridgeResult
    }
#endif

private actor WriteRecorder {
    private(set) var frames: [Data] = []

    var responseIDs: [Int] {
        frames.compactMap { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  object["result"] != nil,
                  let number = object["id"] as? NSNumber
            else {
                return nil
            }
            return number.intValue
        }
    }

    func record(_ frame: Data) {
        frames.append(frame)
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEnteredAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension PersistentMCPResponseDeliveryTests {
    static func closeIfOpen(_ fd: Int32) {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
            }
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    static func fillPipeToCapacity(_ fd: Int32) throws {
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        let payload = [UInt8](repeating: 0x58, count: 4096)
        while true {
            let result = payload.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress, bytes.count)
            }
            if result > 0 { continue }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func readToEOF(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let result = Darwin.read(fd, &buffer, buffer.count)
            if result > 0 {
                data.append(contentsOf: buffer[0 ..< result])
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                return data
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    static func readLine(from fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(fd, &byte, 1)
            if result == 1 {
                data.append(byte)
                if byte == UInt8(ascii: "\n") { return data }
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                throw POSIXError(.ECONNRESET)
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func deliver(
        _ frame: Data,
        direction: JSONRPCBridgeDirection,
        ledger: JSONRPCBridgeLedger,
        writes: WriteRecorder
    ) async throws {
        _ = try await JSONRPCBridgeDelivery.forward(
            frame: frame,
            direction: direction,
            ledger: ledger
        ) { frame in
            await writes.record(frame)
        }
    }

    func request(id: Int, tool: String = "read_file") -> Data {
        line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"path\":\"/tmp/fixture\"}}")
    }

    func response(id: Int) -> Data {
        line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"content\":[]}}")
    }

    func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
