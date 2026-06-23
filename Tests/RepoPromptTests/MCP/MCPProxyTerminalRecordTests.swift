import Darwin
import Foundation
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class MCPProxyTerminalRecordTests: XCTestCase {
    func testHostInputFailuresExitWithoutRetryAndRetainHostProvenance() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "host-input-test")
        _ = try await ledger.beginConnection()
        let snapshot = await ledger.snapshot()

        let cases: [(reason: CLIHostDisconnectProvenance.Reason, errno: Int32, failure: () throws -> Void)] = [
            (.stdinPollFailed, EBADF, { try validateCLIHostInputPollResult(-1, errno: EBADF) }),
            (.stdinReadFailed, EIO, { try validateCLIHostInputReadResult(-1, errno: EIO) })
        ]

        for testCase in cases {
            let runtimeError: CLIRuntimeError
            do {
                try testCase.failure()
                XCTFail("Expected host input validation to fail")
                continue
            } catch let error as CLIRuntimeError {
                runtimeError = error
            } catch {
                XCTFail("Unexpected host input validation error: \(error)")
                continue
            }
            guard case let .hostDisconnected(provenance) = runtimeError else {
                return XCTFail("Expected host-disconnected runtime error")
            }

            XCTAssertEqual(provenance.reason, testCase.reason)
            XCTAssertEqual(provenance.errno, testCase.errno)
            XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))
            XCTAssertEqual(mcpCLIExitCode(for: runtimeError), .ok)
            XCTAssertFalse(CLIEventLogger.shouldPersistEvent(for: runtimeError))

            let record = CLIProxyRuntimePolicy.makeTerminalRecord(
                sessionToken: "host-input-session",
                localPID: 101,
                initialParentPID: 202,
                ledgerSnapshot: snapshot,
                runtimeError: runtimeError,
                fallbackReason: "unexpected_fallback"
            )
            XCTAssertEqual(record.layer, .proxy)
            XCTAssertEqual(record.initiator, .host)
            XCTAssertEqual(record.reason, testCase.reason.rawValue)
            XCTAssertEqual(record.errno, testCase.errno)
            XCTAssertTrue(record.errorDescription?.contains("errno=\(testCase.errno)") == true)
        }

        XCTAssertNoThrow(try validateCLIHostInputPollResult(-1, errno: EINTR))
        XCTAssertNoThrow(try validateCLIHostInputReadResult(-1, errno: EAGAIN))
        XCTAssertNoThrow(try validateCLIHostInputReadResult(-1, errno: EINTR))
    }

    func testSocketReadFailureRemainsRetryablePeerTransportFailure() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "socket-read-test")
        _ = try await ledger.beginConnection()
        let runtimeError = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.readFailed(errno: ECONNRESET)
        )

        XCTAssertTrue(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: runtimeError), "socket_read_failed")

        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "socket-read-session",
            localPID: 303,
            initialParentPID: 404,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )
        XCTAssertEqual(record.initiator, .peer)
        XCTAssertEqual(record.reason, "socket_read_failed")
        XCTAssertEqual(record.errno, ECONNRESET)
    }

    func testLocalSocketReadFailureIsAttributedToTransport() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "local-read-test")
        _ = try await ledger.beginConnection()
        let runtimeError = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.readFailed(errno: EIO)
        )

        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "local-read-session",
            localPID: 303,
            initialParentPID: 404,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )
        XCTAssertEqual(record.initiator, .transport)
        XCTAssertEqual(record.reason, "socket_read_failed")
        XCTAssertEqual(record.errno, EIO)
    }

    func testCancellationNormalizesToStableHostTaskProvenance() async throws {
        let runtimeError = try XCTUnwrap(
            CLIProxyRuntimePolicy.normalizedTerminalRuntimeError(for: CancellationError())
        )
        guard case let .hostDisconnected(provenance) = runtimeError else {
            return XCTFail("Expected host-disconnected cancellation provenance")
        }
        XCTAssertEqual(provenance.reason, .taskCancelled)
        XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))

        let ledger = JSONRPCBridgeLedger(connectionID: "cancelled-proxy-test")
        _ = try await ledger.beginConnection()
        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "cancelled-proxy-session",
            localPID: 505,
            initialParentPID: 606,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "proxy_unexpected_error"
        )
        XCTAssertEqual(record.initiator, .host)
        XCTAssertEqual(record.reason, CLIHostDisconnectProvenance.Reason.taskCancelled.rawValue)
        XCTAssertNotEqual(record.reason, "proxy_unexpected_error")
    }

    func testProxyTaskGroupOutcomesClassifyCleanCompletionAndCancellation() throws {
        XCTAssertNil(MCPServiceProxyTaskGroupPolicy.terminalRuntimeError(
            firstCompletedOutcome: .transportCompleted,
            serviceTaskIsCancelled: false
        ))

        let cancelledOutcomes: [(MCPServiceProxyTaskOutcome, Bool)] = [
            (.transportCompleted, true),
            (.killSignalWaitCancelled, false),
            (.ppidWatchdogCancelled, false)
        ]
        for (outcome, serviceTaskIsCancelled) in cancelledOutcomes {
            let runtimeError = try XCTUnwrap(MCPServiceProxyTaskGroupPolicy.terminalRuntimeError(
                firstCompletedOutcome: outcome,
                serviceTaskIsCancelled: serviceTaskIsCancelled
            ))
            guard case let .hostDisconnected(provenance) = runtimeError else {
                return XCTFail("Expected host-disconnected cancellation for \(outcome)")
            }
            XCTAssertEqual(provenance.reason, .taskCancelled)
        }
    }

    func testTerminalRecordCopiesLiveLedgerSnapshotAndServerReason() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "terminal-record-test")
        _ = try await ledger.beginConnection()
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_file"}}"#.utf8)
        let prepared = try await ledger.prepare(frame: request, direction: .clientToServer)
        try await ledger.commit(prepared)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertTrue(snapshot.hasForwardedProtocolFrame)

        let runtimeError = CLIRuntimeError.terminatedByServer(CLIServerTerminationProvenance(
            reason: .runCompleted,
            message: "Run completed"
        ))
        let record = CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "terminal-record-session",
            localPID: 505,
            initialParentPID: 606,
            ledgerSnapshot: snapshot,
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )

        XCTAssertEqual(record.initiator, .app)
        XCTAssertEqual(record.reason, TerminationReason.runCompleted.rawValue)
        XCTAssertEqual(record.localPID, 505)
        XCTAssertEqual(record.peerPID, 606)
        XCTAssertEqual(record.connectionGeneration, snapshot.connectionGeneration)
        XCTAssertEqual(record.bridgeActiveRequestCount, snapshot.activeRequestCount)
        XCTAssertEqual(record.bridgeResponseInDeliveryCount, snapshot.responseInDeliveryCount)
        XCTAssertEqual(record.bridgeCancellationTombstoneCount, snapshot.cancellationTombstoneCount)
        XCTAssertEqual(record.bridgeRecentCompletionCount, snapshot.recentCompletionCount)
        XCTAssertEqual(record.bridgePendingTransactionCount, snapshot.pendingTransactionCount)
        XCTAssertEqual(record.bridgeHasForwardedProtocolFrame, snapshot.hasForwardedProtocolFrame)
        XCTAssertEqual(record.errorDescription, "Run completed")
    }
}
