import Foundation
import RepoPromptShared
import XCTest

final class JSONRPCBridgeLedgerTests: XCTestCase {
    func testSameTypedIDCanBeActiveInOppositeDirections() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "1", method: "tools/list"), .clientToServer, ledger)
        try await forward(request(id: "1", method: "sampling/createMessage"), .serverToClient, ledger)

        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 2)

        try await forward(response(id: "1"), .serverToClient, ledger)
        try await forward(response(id: "1"), .clientToServer, ledger)

        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.recentCompletionCount, 2)
    }

    func testNumericAndStringIDsRemainDistinct() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "7", method: "ping"), .clientToServer, ledger)
        try await forward(request(id: #""7""#, method: "ping"), .clientToServer, ledger)
        let activeAfterRequests = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeAfterRequests, 2)

        try await forward(response(id: "7"), .serverToClient, ledger)
        try await forward(response(id: #""7""#), .serverToClient, ledger)
        let activeAfterResponses = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeAfterResponses, 0)
    }

    func testImmediateResponseCanCommitBeforeRequestWriteCommit() async throws {
        let ledger = try await makeLedger()
        let preparedRequest = try await ledger.prepare(
            frame: request(id: "101", method: "tools/call", tool: "read_file"),
            direction: .clientToServer
        )
        let preparedResponse = try await ledger.prepare(
            frame: response(id: "101"),
            direction: .serverToClient
        )

        let inDeliveryCount = await ledger.snapshot().responseInDeliveryCount
        XCTAssertEqual(inDeliveryCount, 1)
        try await ledger.commit(preparedResponse)
        try await ledger.commit(preparedRequest)

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.pendingTransactionCount, 0)
    }

    func testMixedBatchIsOneTransactionalReservation() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "9", method: "sampling/createMessage"), .serverToClient, ledger)

        let batch = line(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":9,"result":{}}]"#)
        let prepared = try await ledger.prepare(frame: batch, direction: .clientToServer)
        XCTAssertEqual(prepared.messages.map(\.kind), [.request, .notification, .response])
        try await ledger.commit(prepared)

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertEqual(snapshot.recentCompletionCount, 1)
    }

    func testBatchValidationFailureDoesNotPartiallyReserveIDs() async throws {
        let ledger = try await makeLedger()
        let batch = line(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#)

        do {
            _ = try await ledger.prepare(frame: batch, direction: .clientToServer)
            XCTFail("Expected duplicate ID failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .duplicateActiveID(.clientToServer, .number(1)))
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.pendingTransactionCount, 0)
        XCTAssertEqual(snapshot.terminalReason, "duplicate_active_id")
    }

    func testMalformedClientJSONIsForwardedAndNullErrorResponseIsAccepted() async throws {
        let ledger = try await makeLedger()
        let malformed = line(#"{"jsonrpc":"2.0","id":1,"method":"ping""#)
        let prepared = try await ledger.prepare(frame: malformed, direction: .clientToServer)
        XCTAssertEqual(prepared.messages.map(\.kind), [.invalidClientMessage])
        try await ledger.commit(prepared)

        let nullError = line(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#)
        try await forward(nullError, .serverToClient, ledger)
        let activeAfterResponses = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeAfterResponses, 0)
    }

    func testInvalidClientObjectWithExtractableIDIsCorrelated() async throws {
        let ledger = try await makeLedger()
        try await forward(line(#"{"jsonrpc":"2.0","id":"bad","params":{}}"#), .clientToServer, ledger)
        let activeCount = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeCount, 1)

        try await forward(response(id: #""bad""#), .serverToClient, ledger)
        let activeAfterResponses = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeAfterResponses, 0)
    }

    func testSemanticallyInvalidBackendEnvelopesFailClosed() async throws {
        let invalidFrames = [
            line(#"{"id":1,"result":{}}"#),
            line(#"{"jsonrpc":"1.0","id":1,"result":{}}"#),
            line(#"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}"#),
            line(#"{"jsonrpc":"2.0","id":1,"method":"ping","result":{}}"#),
            line(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        ]

        for frame in invalidFrames {
            let ledger = try await makeLedger()
            do {
                _ = try await ledger.prepare(frame: frame, direction: .serverToClient)
                XCTFail("Expected semantic backend validation failure")
            } catch let error as JSONRPCBridgeLedgerError {
                XCTAssertEqual(error, .malformedBackendFrame)
            }
        }
    }

    func testMalformedBackendFrameFailsClosed() async throws {
        let ledger = try await makeLedger()
        do {
            _ = try await ledger.prepare(frame: line("not-json"), direction: .serverToClient)
            XCTFail("Expected malformed backend failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .malformedBackendFrame)
        }
        let terminalReason = await ledger.snapshot().terminalReason
        XCTAssertEqual(terminalReason, "malformed_backend_frame")
    }

    func testCancellationCreatesBoundedTombstoneAndLateResponseIsDiscarded() async throws {
        let ledger = try await makeLedger(configuration: .init(cancellationTombstoneTTL: 10))
        try await forward(request(id: "5", method: "tools/call", tool: "read_file"), .clientToServer, ledger, now: 100)
        try await forward(cancellation(id: "5"), .clientToServer, ledger, now: 101)

        var snapshot = await ledger.snapshot(now: 101)
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.cancellationTombstoneCount, 1)

        let late = try await ledger.prepare(frame: response(id: "5"), direction: .serverToClient, now: 102)
        XCTAssertEqual(late.disposition, .discardCancelledResponse)
        try await ledger.commit(late, now: 102)

        do {
            _ = try await ledger.prepare(frame: request(id: "5", method: "ping"), direction: .clientToServer, now: 109)
            XCTFail("Cancelled ID must remain unavailable until expiry")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .cancelledIDReuse(.clientToServer, .number(5)))
        }

        snapshot = await ledger.snapshot(now: 111)
        XCTAssertEqual(snapshot.cancellationTombstoneCount, 0)
    }

    func testMixedBatchFiltersOnlyLateCancelledResponse() async throws {
        let ledger = try await makeLedger(configuration: .init(cancellationTombstoneTTL: 10))
        try await forward(request(id: "5", method: "ping"), .clientToServer, ledger, now: 100)
        try await forward(cancellation(id: "5"), .clientToServer, ledger, now: 101)
        try await forward(request(id: "6", method: "ping"), .clientToServer, ledger, now: 101)

        let batch = line(#"[{"jsonrpc":"2.0","id":5,"result":{}},{"jsonrpc":"2.0","id":6,"result":{}}]"#)
        let prepared = try await ledger.prepare(frame: batch, direction: .serverToClient, now: 102)
        XCTAssertEqual(prepared.disposition, .forwardFilteredCancelledResponses)
        let delivered = try XCTUnwrap(prepared.deliveryFrame)
        let deliveredString = String(decoding: delivered, as: UTF8.self)
        XCTAssertFalse(deliveredString.contains(#""id":5"#))
        XCTAssertTrue(deliveredString.contains(#""id":6"#))
        try await ledger.commit(prepared, now: 102)

        let snapshot = await ledger.snapshot(now: 102)
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.cancellationTombstoneCount, 1)
    }

    func testCancelledIDCanBeReusedAfterTombstoneExpiry() async throws {
        let ledger = try await makeLedger(configuration: .init(cancellationTombstoneTTL: 10))
        try await forward(request(id: "8", method: "ping"), .clientToServer, ledger, now: 100)
        try await forward(cancellation(id: "8"), .clientToServer, ledger, now: 101)
        let prepared = try await ledger.prepare(
            frame: request(id: "8", method: "tools/list"),
            direction: .clientToServer,
            now: 112
        )
        try await ledger.commit(prepared, now: 112)
        let activeRequestCount = await ledger.snapshot(now: 112).activeRequestCount
        XCTAssertEqual(activeRequestCount, 1)
    }

    func testResponsePreparedBeforeCancellationCommitWinsRace() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "6", method: "ping"), .clientToServer, ledger)
        let preparedResponse = try await ledger.prepare(frame: response(id: "6"), direction: .serverToClient)
        let preparedCancellation = try await ledger.prepare(frame: cancellation(id: "6"), direction: .clientToServer)

        try await ledger.commit(preparedCancellation)
        try await ledger.commit(preparedResponse)

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.cancellationTombstoneCount, 0)
    }

    func testNormalCompletionAllowsImmediateIDReuse() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "12", method: "ping"), .clientToServer, ledger)
        try await forward(response(id: "12"), .serverToClient, ledger)
        try await forward(request(id: "12", method: "tools/list"), .clientToServer, ledger)
        let activeCount = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeCount, 1)
    }

    func testDuplicateActiveIDIsTerminal() async throws {
        let ledger = try await makeLedger()
        try await forward(request(id: "33", method: "ping"), .clientToServer, ledger)
        do {
            _ = try await ledger.prepare(frame: request(id: "33", method: "ping"), direction: .clientToServer)
            XCTFail("Expected duplicate active ID failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .duplicateActiveID(.clientToServer, .number(33)))
        }
        let terminalReason = await ledger.snapshot().terminalReason
        XCTAssertNotNil(terminalReason)
    }

    func testUncertainWriteAbortsWholeSessionWithoutCommit() async throws {
        struct WriteFailure: Error {}
        let ledger = try await makeLedger()

        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: request(id: "44", method: "ping"),
                direction: .clientToServer,
                ledger: ledger
            ) { _ in
                throw WriteFailure()
            }
            XCTFail("Expected write failure")
        } catch is WriteFailure {}

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, "destination_write_uncertain")
        XCTAssertFalse(snapshot.canReconnect)
        XCTAssertEqual(snapshot.pendingTransactionCount, 0)
    }

    func testCleanEOFAndEOFWithOutstandingWorkAreDistinguished() async throws {
        let cleanLedger = try await makeLedger()
        let cleanDisposition = await cleanLedger.noteEOF(direction: .clientToServer)
        XCTAssertEqual(cleanDisposition, .clean)

        let drainingLedger = try await makeLedger()
        try await forward(request(id: "55", method: "ping"), .clientToServer, drainingLedger)
        let inputDisposition = await drainingLedger.noteEOF(direction: .clientToServer)
        XCTAssertEqual(inputDisposition, .clean)
        let activeDrainSnapshot = await drainingLedger.snapshot()
        XCTAssertEqual(activeDrainSnapshot.activeRequestCount, 1)
        try await forward(response(id: "55"), .serverToClient, drainingLedger)
        let completedDrainSnapshot = await drainingLedger.snapshot()
        XCTAssertEqual(completedDrainSnapshot.activeRequestCount, 0)

        let serverRequestLedger = try await makeLedger()
        try await forward(request(id: "56", method: "roots/list"), .serverToClient, serverRequestLedger)
        let impossibleResponseDisposition = await serverRequestLedger.noteEOF(direction: .clientToServer)
        XCTAssertEqual(
            impossibleResponseDisposition,
            .terminal(reason: "eof_with_outstanding_work")
        )

        let activeLedger = try await makeLedger()
        try await forward(request(id: "57", method: "ping"), .clientToServer, activeLedger)
        let activeDisposition = await activeLedger.noteEOF(direction: .serverToClient)
        XCTAssertEqual(activeDisposition, .terminal(reason: "eof_with_outstanding_work"))

        let partialLedger = try await makeLedger()
        let partialDisposition = await partialLedger.noteEOF(
            direction: .serverToClient,
            pendingByteCount: 4
        )
        XCTAssertEqual(partialDisposition, .terminal(reason: "eof_with_incomplete_frame"))
    }

    func testTombstoneCapacityFailsClosedInsteadOfEvictingLiveProtection() async throws {
        let ledger = try await makeLedger(configuration: .init(
            cancellationTombstoneTTL: 60,
            maximumCancellationTombstones: 1
        ))
        try await forward(request(id: "1", method: "ping"), .clientToServer, ledger)
        try await forward(cancellation(id: "1"), .clientToServer, ledger)
        try await forward(request(id: "2", method: "ping"), .clientToServer, ledger)

        do {
            try await forward(cancellation(id: "2"), .clientToServer, ledger)
            XCTFail("Expected tombstone capacity failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .tombstoneCapacityExceeded(1))
        }
        let terminalReason = await ledger.snapshot().terminalReason
        XCTAssertEqual(terminalReason, "cancellation_tombstone_capacity_exceeded")
    }

    func testRecentCompletionDiagnosticsAreBounded() async throws {
        let ledger = try await makeLedger(configuration: .init(maximumRecentCompletions: 2))
        for id in 1 ... 3 {
            try await forward(request(id: String(id), method: "ping"), .clientToServer, ledger)
            try await forward(response(id: String(id)), .serverToClient, ledger)
        }
        let recentCompletionCount = await ledger.snapshot().recentCompletionCount
        XCTAssertEqual(recentCompletionCount, 2)
    }

    func testStartupOnlyReconnectState() async throws {
        let ledger = try await makeLedger()
        var reconnectSnapshot = await ledger.snapshot()
        XCTAssertTrue(reconnectSnapshot.canReconnect)
        let startupFailureWasTerminal = await ledger.recordConnectionFailure("startup_socket_reset")
        XCTAssertFalse(startupFailureWasTerminal)
        reconnectSnapshot = await ledger.snapshot()
        XCTAssertTrue(reconnectSnapshot.canReconnect)
        _ = try await ledger.beginConnection()

        try await forward(line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), .clientToServer, ledger)
        let activeFailureWasTerminal = await ledger.recordConnectionFailure("socket_reset_after_traffic")
        XCTAssertTrue(activeFailureWasTerminal)
        reconnectSnapshot = await ledger.snapshot()
        XCTAssertFalse(reconnectSnapshot.canReconnect)

        let preparedLedger = try await makeLedger()
        _ = try await preparedLedger.prepare(
            frame: line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
            direction: .clientToServer
        )
        let preparedSnapshot = await preparedLedger.snapshot()
        XCTAssertEqual(preparedSnapshot.activeRequestCount, 0)
        XCTAssertEqual(preparedSnapshot.pendingTransactionCount, 1)
        XCTAssertFalse(preparedSnapshot.hasForwardedProtocolFrame)
        XCTAssertFalse(preparedSnapshot.canReconnect)

        let preparedFailureWasTerminal = await preparedLedger.recordConnectionFailure(
            "socket_reset_with_prepared_transaction"
        )
        XCTAssertTrue(preparedFailureWasTerminal)
        let terminalPreparedSnapshot = await preparedLedger.snapshot()
        XCTAssertEqual(terminalPreparedSnapshot.terminalReason, "socket_reset_with_prepared_transaction")
        XCTAssertFalse(terminalPreparedSnapshot.canReconnect)
    }

    func testTraceMetadataContainsHashAndNeverPayload() async throws {
        final class TraceBox: @unchecked Sendable {
            let lock = NSLock()
            var events: [MCPResponseDeliveryTraceEvent] = []
            func append(_ event: MCPResponseDeliveryTraceEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }
        }

        let box = TraceBox()
        let ledger = JSONRPCBridgeLedger(traceSink: { box.append($0) })
        _ = try await ledger.beginConnection()
        let secret = "do-not-log-this-argument"
        try await forward(
            line("{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"path\":\"\(secret)\"}}"),
            .clientToServer,
            ledger
        )

        let descriptions = box.events.map(\.description).joined(separator: "\n")
        XCTAssertTrue(descriptions.contains("id=number:77"))
        XCTAssertTrue(descriptions.contains("tool=read_file"))
        XCTAssertTrue(descriptions.contains("sha256="))
        XCTAssertFalse(descriptions.contains(secret))
    }
}

private extension JSONRPCBridgeLedgerTests {
    func makeLedger(
        configuration: JSONRPCBridgeLedger.Configuration = .init()
    ) async throws -> JSONRPCBridgeLedger {
        let ledger = JSONRPCBridgeLedger(configuration: configuration)
        _ = try await ledger.beginConnection()
        return ledger
    }

    func forward(
        _ frame: Data,
        _ direction: JSONRPCBridgeDirection,
        _ ledger: JSONRPCBridgeLedger,
        now: TimeInterval = 1
    ) async throws {
        let prepared = try await ledger.prepare(frame: frame, direction: direction, now: now)
        try await ledger.commit(prepared, now: now)
    }

    func request(id: String, method: String, tool: String? = nil) -> Data {
        let params = tool.map { ",\"params\":{\"name\":\"\($0)\"}" } ?? ""
        return line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\"\(params)}")
    }

    func response(id: String) -> Data {
        line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{}}")
    }

    func cancellation(id: String) -> Data {
        line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}")
    }

    func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
