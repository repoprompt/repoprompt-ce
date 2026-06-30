import Darwin
import Foundation
@testable import RepoPrompt
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class PersistentMCPResponseDeliveryTests: XCTestCase {
    func testResponseDeliveryDrainWaitsForMatchingResponseWrite() async {
        let gate = MCPTransportResponseDeliveryGate()
        gate.recordAcceptedClientFrame(request(id: 808))
        XCTAssertEqual(gate.snapshot().pendingRequestCount, 1)

        let waitTask = Task {
            await gate.waitUntilDrained()
        }
        for _ in 0 ..< 100 where gate.snapshot().waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.snapshot().waiterCount, 1)

        gate.recordDeliveredServerFrame(response(id: 909))
        XCTAssertEqual(gate.snapshot().pendingRequestCount, 1)
        XCTAssertEqual(gate.snapshot().waiterCount, 1)

        gate.recordDeliveredServerFrame(response(id: 808))
        let didDrain = await waitTask.value
        XCTAssertTrue(didDrain)
        XCTAssertEqual(gate.snapshot().pendingRequestCount, 0)
        XCTAssertEqual(gate.snapshot().waiterCount, 0)
    }

    func testResponseDeliveryDrainFailsWhenTransportClosesWithOutstandingRequest() async {
        let gate = MCPTransportResponseDeliveryGate()
        gate.recordAcceptedClientFrame(request(id: 818))

        let waitTask = Task {
            await gate.waitUntilDrained()
        }
        for _ in 0 ..< 100 where gate.snapshot().waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.snapshot().waiterCount, 1)

        gate.close()
        let didDrain = await waitTask.value
        XCTAssertFalse(didDrain)
        XCTAssertTrue(gate.snapshot().isTerminal)
    }

    func testOutstandingReplayStateOnlyCachesReplayableSingleRequests() async {
        let replayState = MCPOutstandingRequestReplayState()
        let unsafeToolCall = line(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"apply_edits","arguments":{"path":"README.md","search":"a","replace":"b"}}}"#)
        let batchedSafeRequest = line(#"[{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}]"#)
        let safeToolCall = line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let safeMethodRequest = line(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#)
        let unsafeWorkspaceExport = line(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"export","path":"context.txt"}}}"#)
        let safeWorkspaceSnapshot = line(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"snapshot","include":["tokens"]}}}"#)

        await replayState.recordForwardedClientFrame(unsafeToolCall)
        await replayState.recordForwardedClientFrame(batchedSafeRequest)
        await replayState.recordForwardedClientFrame(unsafeWorkspaceExport)
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(safeToolCall)
        await replayState.recordForwardedClientFrame(safeMethodRequest)
        await replayState.recordForwardedClientFrame(safeWorkspaceSnapshot)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 3)
        Self.assertJSONLineEqual(frames[0], safeToolCall)
        Self.assertJSONLineEqual(frames[1], safeMethodRequest)
        Self.assertJSONLineEqual(frames[2], safeWorkspaceSnapshot)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 2)
        Self.assertJSONLineEqual(frames[0], safeMethodRequest)
        Self.assertJSONLineEqual(frames[1], safeWorkspaceSnapshot)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":4,"result":{"tools":[]}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], safeWorkspaceSnapshot)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":6,"result":{"prompt_tokens":0}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateIgnoresClientResponseForAppOriginatedIDCollision() async {
        let replayState = MCPOutstandingRequestReplayState()
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let clientResponseToAppRequestWithSameID = line(#"{"jsonrpc":"2.0","id":7,"result":{"roots":[]}}"#)
        let serverResponseToHostRequest = line(#"{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"ok"}]}}"#)

        await replayState.recordForwardedClientFrame(hostRequest)
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordForwardedClientFrame(clientResponseToAppRequestWithSameID)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordDeliveredServerFrame(serverResponseToHostRequest)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateUsesStrictJSONRPCIDs() async {
        let replayState = MCPOutstandingRequestReplayState()
        let invalidFractionalRequest = line(#"{"jsonrpc":"2.0","id":7.5,"method":"tools/list","params":{}}"#)
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#)

        await replayState.recordForwardedClientFrame(invalidFractionalRequest)
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(hostRequest)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7.5}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateDoesNotReaddStaleRequestWhenResponseCommitsFirst() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let replayState = MCPOutstandingRequestReplayState()
        let requestFrame = line(#"{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}"#)
        let responseFrame = line(#"{"jsonrpc":"2.0","id":8,"result":{"tools":[]}}"#)

        let preparedRequest = try await ledger.prepare(frame: requestFrame, direction: .clientToServer)
        let recordedRequest = await replayState.recordPreparedClientRequestFrame(requestFrame, prepared: preparedRequest)
        XCTAssertTrue(recordedRequest)

        let preparedResponse = try await ledger.prepare(frame: responseFrame, direction: .serverToClient)
        try await ledger.commit(preparedResponse)
        await replayState.recordDeliveredServerFrame(responseFrame, prepared: preparedResponse)
        try await ledger.commit(preparedRequest)

        let frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateRemovesResponsesByRequestOrdinalWhenIDIsReused() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let replayState = MCPOutstandingRequestReplayState()
        let oldRequest = line(#"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}"#)
        let oldResponse = line(#"{"jsonrpc":"2.0","id":9,"result":{"tools":[]}}"#)
        let newRequest = line(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)

        let preparedOldRequest = try await ledger.prepare(frame: oldRequest, direction: .clientToServer)
        let recordedOldRequest = await replayState.recordPreparedClientRequestFrame(oldRequest, prepared: preparedOldRequest)
        XCTAssertTrue(recordedOldRequest)
        try await ledger.commit(preparedOldRequest)

        let preparedOldResponse = try await ledger.prepare(frame: oldResponse, direction: .serverToClient)
        try await ledger.commit(preparedOldResponse)

        let preparedNewRequest = try await ledger.prepare(frame: newRequest, direction: .clientToServer)
        let recordedNewRequest = await replayState.recordPreparedClientRequestFrame(newRequest, prepared: preparedNewRequest)
        XCTAssertTrue(recordedNewRequest)
        try await ledger.commit(preparedNewRequest)

        await replayState.recordDeliveredServerFrame(oldResponse, prepared: preparedOldResponse)
        let frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        Self.assertJSONLineEqual(frames[0], newRequest)
    }

    func testTerminateControlNotificationSurfacesAsServerTermination() async throws {
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
        let resultBox = BridgeTaskResultBox()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                resultBox.store(.success(()))
            } catch {
                resultBox.store(.failure(error))
            }
        }
        defer { bridgeTask.cancel() }

        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1

        let notification = try XCTUnwrap(
            RepoPromptControlNotification<RepoPromptTerminateParams>.terminate(
                reason: .toolExecutionWatchdog,
                message: "watchdog fired"
            ).encodedJSONLine()
        )
        try Self.writeAll(notification, to: sockets[1])

        let completed = await resultBox.waitUntilStored(timeout: .seconds(2))
        XCTAssertTrue(completed)
        guard case let .failure(error) = resultBox.load(),
              let socketError = error as? SocketProxyError,
              case let .terminatedByServer(reason, message) = socketError
        else {
            XCTFail("Expected terminate control notification to surface as server termination")
            return
        }

        XCTAssertEqual(reason, .toolExecutionWatchdog)
        XCTAssertEqual(message, "watchdog fired")
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, TerminationReason.toolExecutionWatchdog.rawValue)
        XCTAssertFalse(snapshot.canReconnect)
    }

    func testInitializeReplayResultMismatchFailsClosedWithoutRetry() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach(Self.closeIfOpen) }

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"resume-test","version":"1"}}}"#)
        let originalResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"RepoPrompt CE","version":"old"}}}"#)
        let changedResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{},"resources":{}},"serverInfo":{"name":"RepoPrompt CE","version":"new"}}}"#)
        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let originalResult = try XCTUnwrap(MCPInitializeReplayState.jsonObject(from: originalResponse)?["result"])
        let originalFingerprint = try XCTUnwrap(MCPInitializeReplayState.initializeCompatibilityFingerprint(originalResult))
        let plan = MCPInitializeReplayPlan(
            initializeFrame: initializeFrame,
            initializeRequestID: .number(1),
            initializeResultFingerprint: originalFingerprint,
            initializedFrame: initializedFrame
        )

        let replayTask = Task {
            try await BootstrapSocketProxy.replayInitializedSession(
                plan,
                socketFD: sockets[0],
                timeout: 2
            )
        }
        XCTAssertEqual(try Self.readLine(from: sockets[1], timeout: 2), initializeFrame)
        try Self.writeAll(changedResponse, to: sockets[1])

        do {
            try await replayTask.value
            XCTFail("Expected initialize replay result mismatch to fail closed")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .terminal("mcp_session_resume_initialize_replay_result_mismatch"))
            XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: .connectionFailed(underlying: error)))
        } catch {
            XCTFail("Unexpected replay error: \(error)")
        }
    }

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

    func testIdleInitializedReconnectReplaysInitializeWithoutDuplicateHostResponse() async throws {
        var firstSockets = [Int32](repeating: -1, count: 2)
        var secondSockets = [Int32](repeating: -1, count: 2)
        var hostSockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &firstSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &secondSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &hostSockets), 0)

        var firstBridgeTask: Task<Void, Never>?
        var secondBridgeTask: Task<Void, Never>?
        defer {
            firstBridgeTask?.cancel()
            secondBridgeTask?.cancel()
            (firstSockets + secondSockets + hostSockets).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        let replayState = MCPInitializeReplayState()
        _ = try await ledger.beginConnection()

        let hostFD = hostSockets[0]
        let bridgeHostFD = hostSockets[1]
        let firstBridgeFD = firstSockets[0]
        let firstAppFD = firstSockets[1]
        let firstResult = BridgeTaskResultBox()
        firstBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: firstBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                firstResult.store(.success(()))
            } catch {
                firstResult.store(.failure(error))
            }
        }

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"resume-test","version":"1"}}}"#)
        let initializeResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"RepoPrompt CE","version":"test"}}}"#)
        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let preResponseBackendNotification = line(#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"resume-before-response"}}"#)
        let postResponseBackendNotification = line(#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"resume-after-response"}}"#)

        try Self.writeAll(initializeFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(initializeResponse, to: firstAppFD)
        XCTAssertEqual(try Self.readLine(from: hostFD, timeout: 2), initializeResponse)
        try Self.writeAll(initializedFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializedFrame)

        _ = Darwin.shutdown(firstAppFD, SHUT_RDWR)
        Self.closeIfOpen(firstSockets[1])
        firstSockets[1] = -1
        let firstBridgeCompleted = await firstResult.waitUntilStored(timeout: .seconds(2))
        XCTAssertTrue(firstBridgeCompleted)
        guard case let .failure(firstError) = firstResult.load(),
              let socketError = firstError as? SocketProxyError,
              case .serverClosed = socketError
        else {
            XCTFail("Expected idle app socket close to surface as serverClosed before the retry loop handles it")
            return
        }

        let failureWasTerminal = await ledger.recordConnectionFailure("app_socket_closed")
        XCTAssertFalse(failureWasTerminal)
        var snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.hasForwardedProtocolFrame)
        XCTAssertTrue(snapshot.canReconnect)
        _ = try await ledger.beginConnection()

        let plan: MCPInitializeReplayPlan
        switch await Self.waitUntilReplayPlanReady(replayState) {
        case let .success(value):
            plan = value
        case let .failure(reason):
            throw reason
        }

        let secondBridgeFD = secondSockets[0]
        let secondAppFD = secondSockets[1]
        let replayTask = Task {
            try await BootstrapSocketProxy.replayInitializedSession(
                plan,
                socketFD: secondBridgeFD,
                timeout: 2
            )
        }
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(preResponseBackendNotification + initializeResponse + postResponseBackendNotification, to: secondAppFD)
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializedFrame)
        let initialSocketBytes = try await replayTask.value

        let secondResult = BridgeTaskResultBox()
        secondBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: secondBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    bridgeLedger: ledger,
                    faultRule: nil,
                    initialSocketBytes: initialSocketBytes
                )
                secondResult.store(.success(()))
            } catch {
                secondResult.store(.failure(error))
            }
        }

        XCTAssertEqual(
            try Self.readLine(from: hostFD, timeout: 2),
            preResponseBackendNotification,
            "Replay must buffer app frames that arrive before the initialize response"
        )
        XCTAssertEqual(
            try Self.readLine(from: hostFD, timeout: 2),
            postResponseBackendNotification,
            "Replay must not consume app frames coalesced after the initialize response"
        )

        let toolRequest = line(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let toolResponse = line(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#)
        try Self.writeAll(toolRequest, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), toolRequest)
        try Self.writeAll(toolResponse, to: secondAppFD)
        XCTAssertEqual(
            try Self.readLine(from: hostFD, timeout: 2),
            toolResponse,
            "The helper must consume the replay initialize response internally before forwarding later host traffic"
        )

        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertNil(snapshot.terminalReason)
    }

    func testPendingInitializeResponseReconnectForwardsReplayedResponseToHost() async throws {
        var firstSockets = [Int32](repeating: -1, count: 2)
        var secondSockets = [Int32](repeating: -1, count: 2)
        var hostSockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &firstSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &secondSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &hostSockets), 0)

        var firstBridgeTask: Task<Void, Never>?
        var secondBridgeTask: Task<Void, Never>?
        defer {
            firstBridgeTask?.cancel()
            secondBridgeTask?.cancel()
            (firstSockets + secondSockets + hostSockets).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        let replayState = MCPInitializeReplayState()
        _ = try await ledger.beginConnection()

        let hostFD = hostSockets[0]
        let bridgeHostFD = hostSockets[1]
        let firstBridgeFD = firstSockets[0]
        let firstAppFD = firstSockets[1]
        let firstResult = BridgeTaskResultBox()
        firstBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: firstBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                firstResult.store(.success(()))
            } catch {
                firstResult.store(.failure(error))
            }
        }

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"resume-test","version":"1"}}}"#)
        let initializeResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"RepoPrompt CE","version":"test"}}}"#)
        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)

        try Self.writeAll(initializeFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializeFrame)

        _ = Darwin.shutdown(firstAppFD, SHUT_RDWR)
        Self.closeIfOpen(firstSockets[1])
        firstSockets[1] = -1
        let firstBridgeCompleted = await firstResult.waitUntilStored(timeout: .seconds(2))
        XCTAssertTrue(firstBridgeCompleted)
        guard case let .failure(firstError) = firstResult.load(),
              let socketError = firstError as? SocketProxyError,
              case .serverClosed = socketError
        else {
            XCTFail("Expected app socket close before initialize response to surface as serverClosed")
            return
        }

        let failureWasTerminal = await ledger.recordConnectionFailure("app_socket_closed_before_initialize_response")
        XCTAssertFalse(failureWasTerminal)
        var snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.hasForwardedProtocolFrame)
        XCTAssertTrue(snapshot.canReconnect)
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertEqual(snapshot.replayableClientRequestCount, 1)
        _ = try await ledger.beginConnection()

        let plan: MCPInitializeReplayPlan
        switch await Self.waitUntilReplayPlanReady(replayState) {
        case let .success(value):
            plan = value
        case let .failure(reason):
            throw reason
        }
        XCTAssertTrue(plan.shouldForwardInitializeResponseToHost)

        let secondBridgeFD = secondSockets[0]
        let secondAppFD = secondSockets[1]
        let replayBufferedBytes = try await BootstrapSocketProxy.replayInitializedSession(
            plan,
            socketFD: secondBridgeFD,
            timeout: 2
        )
        XCTAssertEqual(replayBufferedBytes, Data())
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializeFrame)

        let secondResult = BridgeTaskResultBox()
        secondBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: secondBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                secondResult.store(.success(()))
            } catch {
                secondResult.store(.failure(error))
            }
        }

        try Self.writeAll(initializeResponse, to: secondAppFD)
        XCTAssertEqual(
            try Self.readLine(from: hostFD, timeout: 2),
            initializeResponse,
            "The replayed initialize response is the host-visible response when the original response was never delivered"
        )
        try Self.writeAll(initializedFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializedFrame)

        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertNil(snapshot.terminalReason)
    }

    func testInitializeReplayStateReportsUnsupportedResumeReasons() async throws {
        let replayState = MCPInitializeReplayState()
        let missingInitialize = await replayState.replayPlan()
        XCTAssertEqual(
            missingInitialize,
            .failure(.missingInitializeFrame)
        )

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"resume-test"}}}"#)
        await replayState.recordForwardedClientFrame(initializeFrame)
        let pendingInitializeResponse = try await (replayState.replayPlan()).get()
        XCTAssertTrue(pendingInitializeResponse.shouldForwardInitializeResponseToHost)
        XCTAssertNil(pendingInitializeResponse.initializeResultFingerprint)
        XCTAssertNil(pendingInitializeResponse.initializedFrame)

        let initializeResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#)
        await replayState.recordDeliveredServerFrame(initializeResponse)
        let missingInitialized = try await (replayState.replayPlan()).get()
        XCTAssertFalse(missingInitialized.shouldForwardInitializeResponseToHost)
        XCTAssertNotNil(missingInitialized.initializeResultFingerprint)
        XCTAssertNil(missingInitialized.initializedFrame)

        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        await replayState.recordForwardedClientFrame(initializedFrame)
        let replayPlanResult = await replayState.replayPlan()
        let plan = try replayPlanResult.get()
        XCTAssertEqual(plan.initializeFrame, initializeFrame)
        XCTAssertEqual(plan.initializeRequestID, .number(1))
        XCTAssertEqual(plan.initializedFrame, initializedFrame)
        XCTAssertFalse(plan.shouldForwardInitializeResponseToHost)
    }

    func testActiveClientRequestReconnectReplaysOutstandingRequest() async throws {
        var hostSockets = [Int32](repeating: -1, count: 2)
        var firstSockets = [Int32](repeating: -1, count: 2)
        var secondSockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &hostSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &firstSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &secondSockets), 0)

        var firstBridgeTask: Task<Void, Never>?
        var secondBridgeTask: Task<Void, Never>?
        defer {
            firstBridgeTask?.cancel()
            secondBridgeTask?.cancel()
            (hostSockets + firstSockets + secondSockets).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        let replayState = MCPInitializeReplayState()
        let outstandingReplayState = MCPOutstandingRequestReplayState()
        _ = try await ledger.beginConnection()

        let hostFD = hostSockets[0]
        let bridgeHostFD = hostSockets[1]
        let firstBridgeFD = firstSockets[0]
        let firstAppFD = firstSockets[1]
        let firstResult = BridgeTaskResultBox()
        firstBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: firstBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    outstandingRequestReplayState: outstandingReplayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                firstResult.store(.success(()))
            } catch {
                firstResult.store(.failure(error))
            }
        }

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"active-resume-test","version":"1"}}}"#)
        let initializeResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"RepoPrompt CE","version":"test"}}}"#)
        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let toolRequest = line(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let toolResponse = line(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}"#)

        try Self.writeAll(initializeFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(initializeResponse, to: firstAppFD)
        XCTAssertEqual(try Self.readLine(from: hostFD, timeout: 2), initializeResponse)
        try Self.writeAll(initializedFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializedFrame)

        try Self.writeAll(toolRequest, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), toolRequest)

        _ = Darwin.shutdown(firstAppFD, SHUT_RDWR)
        Self.closeIfOpen(firstSockets[1])
        firstSockets[1] = -1
        let firstBridgeCompleted = await firstResult.waitUntilStored(timeout: .seconds(2))
        XCTAssertTrue(firstBridgeCompleted)
        guard case let .failure(firstError) = firstResult.load(),
              let socketError = firstError as? SocketProxyError,
              case .serverClosed = socketError
        else {
            XCTFail("Expected active app socket close to surface as retryable serverClosed before the retry loop handles it")
            return
        }

        let failureWasTerminal = await ledger.recordConnectionFailure("app_socket_closed")
        XCTAssertFalse(failureWasTerminal)
        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertEqual(snapshot.replayableClientRequestCount, 1)
        XCTAssertTrue(snapshot.canReconnect)
        _ = try await ledger.beginConnection()

        let plan: MCPInitializeReplayPlan
        switch await Self.waitUntilReplayPlanReady(replayState) {
        case let .success(value):
            plan = value
        case let .failure(reason):
            throw reason
        }

        let secondBridgeFD = secondSockets[0]
        let secondAppFD = secondSockets[1]
        let replayTask = Task {
            try await BootstrapSocketProxy.replayInitializedSession(
                plan,
                socketFD: secondBridgeFD,
                timeout: 2
            )
            for frame in await outstandingReplayState.replayFrames() {
                try Self.writeAll(frame, to: secondBridgeFD)
            }
        }
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(initializeResponse, to: secondAppFD)
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializedFrame)
        try Self.assertJSONLineEqual(
            Self.readLine(from: secondAppFD, timeout: 2),
            toolRequest
        )
        try await replayTask.value

        let secondResult = BridgeTaskResultBox()
        secondBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: secondBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    outstandingRequestReplayState: outstandingReplayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                secondResult.store(.success(()))
            } catch {
                secondResult.store(.failure(error))
            }
        }

        try Self.writeAll(toolResponse, to: secondAppFD)
        XCTAssertEqual(try Self.readLine(from: hostFD, timeout: 2), toolResponse)

        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        let remainingReplayFrames = await Self.waitUntilReplayFramesDrained(outstandingReplayState)
        XCTAssertEqual(remainingReplayFrames, [])
        XCTAssertNil(snapshot.terminalReason)
    }

    func testClientRequestWrittenAfterAppCloseIsReplayedAfterReconnect() async throws {
        var hostSockets = [Int32](repeating: -1, count: 2)
        var firstSockets = [Int32](repeating: -1, count: 2)
        var secondSockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &hostSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &firstSockets), 0)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &secondSockets), 0)
        var firstBridgeTask: Task<Void, Never>?
        var secondBridgeTask: Task<Void, Never>?
        defer {
            firstBridgeTask?.cancel()
            secondBridgeTask?.cancel()
            (hostSockets + firstSockets + secondSockets).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        let replayState = MCPInitializeReplayState()
        let outstandingReplayState = MCPOutstandingRequestReplayState()
        _ = try await ledger.beginConnection()

        let hostFD = hostSockets[0]
        let bridgeHostFD = hostSockets[1]
        let firstBridgeFD = firstSockets[0]
        let firstAppFD = firstSockets[1]
        try Self.setNoSigPipe(on: firstBridgeFD)
        let firstSocketPoller = ManualBridgeSocketPoller()
        let firstResult = BridgeTaskResultBox()
        firstBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: firstBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    outstandingRequestReplayState: outstandingReplayState,
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await firstSocketPoller.next() }
                )
                firstResult.store(.success(()))
            } catch {
                firstResult.store(.failure(error))
            }
            await firstSocketPoller.markBridgeCompleted()
        }

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"write-resume-test","version":"1"}}}"#)
        let initializeResponse = line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"RepoPrompt CE","version":"test"}}}"#)
        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        let toolRequest = line(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let toolResponse = line(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#)

        try Self.writeAll(initializeFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(initializeResponse, to: firstAppFD)
        await firstSocketPoller.resumeNext(.events(Int16(POLLIN)))
        XCTAssertEqual(try Self.readLine(from: hostFD, timeout: 2), initializeResponse)
        try Self.writeAll(initializedFrame, to: hostFD)
        XCTAssertEqual(try Self.readLine(from: firstAppFD, timeout: 2), initializedFrame)
        let firstSocketPumpIsWaiting = await firstSocketPoller.waitUntilWaiting(count: 2)
        XCTAssertTrue(firstSocketPumpIsWaiting)

        _ = Darwin.shutdown(firstAppFD, SHUT_RDWR)
        Self.closeIfOpen(firstSockets[1])
        firstSockets[1] = -1
        guard try Self.waitUntilSocketPeerClosed(firstBridgeFD, timeout: 5) else {
            XCTFail("Expected app socket close to be visible before writing the post-close client request")
            return
        }
        try Self.writeAll(toolRequest, to: hostFD)

        let firstBridgeCompleted = await firstResult.waitUntilStored(timeout: .seconds(5))
        XCTAssertTrue(firstBridgeCompleted)
        guard case let .failure(firstError) = firstResult.load(),
              let socketError = firstError as? SocketProxyError
        else {
            XCTFail("Expected closed app socket write to fail before the retry loop handles it")
            return
        }
        switch socketError {
        case .writeFailed, .connectionReset, .serverClosed:
            break
        default:
            XCTFail("Expected recoverable app socket write failure, got \(socketError)")
        }

        let failureWasTerminal = await ledger.recordConnectionFailure("socket_write_failed")
        XCTAssertFalse(failureWasTerminal)
        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertEqual(snapshot.replayableClientRequestCount, 1)
        XCTAssertTrue(snapshot.canReconnect)
        _ = try await ledger.beginConnection()

        let plan: MCPInitializeReplayPlan
        switch await Self.waitUntilReplayPlanReady(replayState) {
        case let .success(value):
            plan = value
        case let .failure(reason):
            throw reason
        }

        let secondBridgeFD = secondSockets[0]
        let secondAppFD = secondSockets[1]
        let replayTask = Task {
            try await BootstrapSocketProxy.replayInitializedSession(
                plan,
                socketFD: secondBridgeFD,
                timeout: 2
            )
            for frame in await outstandingReplayState.replayFrames() {
                try Self.writeAll(frame, to: secondBridgeFD)
            }
        }
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializeFrame)
        try Self.writeAll(initializeResponse, to: secondAppFD)
        XCTAssertEqual(try Self.readLine(from: secondAppFD, timeout: 2), initializedFrame)
        try Self.assertJSONLineEqual(
            Self.readLine(from: secondAppFD, timeout: 2),
            toolRequest
        )
        try await replayTask.value

        let secondResult = BridgeTaskResultBox()
        secondBridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: secondBridgeFD,
                    stdinFD: bridgeHostFD,
                    stdoutFD: bridgeHostFD,
                    identityCache: ClientIdentityCache(),
                    initializeReplayState: replayState,
                    outstandingRequestReplayState: outstandingReplayState,
                    bridgeLedger: ledger,
                    faultRule: nil
                )
                secondResult.store(.success(()))
            } catch {
                secondResult.store(.failure(error))
            }
        }

        try Self.writeAll(toolResponse, to: secondAppFD)
        XCTAssertEqual(try Self.readLine(from: hostFD, timeout: 2), toolResponse)

        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        let remainingReplayFrames = await Self.waitUntilReplayFramesDrained(outstandingReplayState)
        XCTAssertEqual(remainingReplayFrames, [])
        XCTAssertNil(snapshot.terminalReason)
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
                    guard case let .failure(rawBridgeError) = bridgeResult else {
                        XCTFail("Expected execution watchdog to terminate the bridge")
                        throw WatchdogBridgeFixtureError.unexpectedBridgeResult
                    }
                    let bridgeTerminalReason: String
                    let runtimeError: CLIRuntimeError
                    switch rawBridgeError {
                    case let bridgeError as JSONRPCBridgeLedgerError:
                        guard case let .terminal(reason) = bridgeError else {
                            XCTFail("Expected terminal ledger error, got \(bridgeError)")
                            throw WatchdogBridgeFixtureError.unexpectedBridgeResult
                        }
                        bridgeTerminalReason = reason
                        runtimeError = .connectionFailed(underlying: bridgeError)
                    case let socketError as SocketProxyError:
                        guard case let .terminatedByServer(reason, message) = socketError else {
                            XCTFail("Expected server termination socket error, got \(socketError)")
                            throw WatchdogBridgeFixtureError.unexpectedBridgeResult
                        }
                        bridgeTerminalReason = reason?.rawValue ?? "terminated_by_server"
                        runtimeError = .terminatedByServer(CLIServerTerminationProvenance(
                            reason: reason,
                            message: message
                        ))
                    default:
                        XCTFail("Unexpected bridge error: \(rawBridgeError)")
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
                        [
                            TerminationReason.toolExecutionWatchdog.rawValue,
                            "socket_eof_with_outstanding_work",
                            "socket_hangup_with_outstanding_work"
                        ]
                        .contains(terminalReason),
                        terminalReason
                    )
                    XCTAssertEqual(bridgeTerminalReason, terminalReason)
                    XCTAssertEqual(terminalSnapshot.activeRequestCount, 1)
                    XCTAssertFalse(terminalSnapshot.canReconnect)
                    XCTAssertEqual(
                        createdHarness.traces.count(phase: "connection_terminal")
                            + createdHarness.traces.count(phase: "terminal_eof"),
                        1
                    )
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
                    XCTAssertEqual(mcpCLIExitCode(for: runtimeError), .terminatedByServer)
                    XCTAssertNotEqual(MCPCLIExitCode.terminatedByServer.rawValue, MCPCLIExitCode.ok.rawValue)

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

    static func setNoSigPipe(on fd: Int32) throws {
        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func waitUntilSocketPeerClosed(_ fd: Int32, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, min(100, max(1, remaining)))
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if pollResult == 0 { continue }

            let revents = Int32(pfd.revents)
            if revents & POLLNVAL != 0 {
                throw POSIXError(.EBADF)
            }
            if revents & (POLLHUP | POLLERR) != 0 {
                return true
            }
            if revents & POLLIN != 0 {
                var byte: UInt8 = 0
                let peeked = Darwin.recv(fd, &byte, 1, MSG_PEEK)
                if peeked == 0 { return true }
                if peeked < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return false
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

    static func readLine(from fd: Int32, timeout: TimeInterval) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, min(100, max(1, remaining)))
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if pollResult == 0 { continue }

            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0, data.isEmpty {
                throw POSIXError(.ECONNRESET)
            }

            let result = Darwin.read(fd, &byte, 1)
            if result == 1 {
                data.append(byte)
                if byte == UInt8(ascii: "\n") { return data }
            } else if result < 0, errno == EINTR {
                continue
            } else if result < 0, errno == EAGAIN {
                continue
            } else if result == 0 {
                throw POSIXError(.ECONNRESET)
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        throw POSIXError(.ETIMEDOUT)
    }

    static func waitUntilReplayFramesDrained(
        _ replayState: MCPOutstandingRequestReplayState,
        timeout: TimeInterval = 2
    ) async -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        var frames = await replayState.replayFrames()
        while !frames.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            frames = await replayState.replayFrames()
        }
        return frames
    }

    static func waitUntilReplayPlanReady(
        _ replayState: MCPInitializeReplayState,
        timeout: TimeInterval = 2
    ) async -> Result<MCPInitializeReplayPlan, MCPInitializeReplayUnavailableReason> {
        let deadline = Date().addingTimeInterval(timeout)
        var result = await replayState.replayPlan()
        while Date() < deadline {
            if case .success = result { return result }
            try? await Task.sleep(nanoseconds: 10_000_000)
            result = await replayState.replayPlan()
        }
        return result
    }

    static func assertJSONLineEqual(
        _ actual: Data,
        _ expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let actualObject = try JSONSerialization.jsonObject(with: actual) as? NSDictionary
            let expectedObject = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
            XCTAssertEqual(actualObject, expectedObject, file: file, line: line)
        } catch {
            XCTFail("Expected valid JSON lines: \(error)", file: file, line: line)
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
