import Foundation
import RepoPromptShared
import XCTest

final class JSONRPCBridgeCancellationTests: XCTestCase {
    func testLateCancelledResponsePreservesUnrelatedExactStringIDAfterTombstoneExpiry() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        try await forward(request(#""7""#), through: ledger, at: 0)
        try await forward(cancel("7"), through: ledger, at: 1)

        let control = try await ledger.prepare(frame: response("7"), direction: .serverToClient, now: 30)
        XCTAssertEqual(control.disposition, .discardCancelledResponse)
        try await ledger.commit(control, now: 30)
        let late = try await ledger.prepare(frame: response("7"), direction: .serverToClient, now: 32)
        XCTAssertEqual(late.disposition, .discardCancelledResponse)
        XCTAssertNil(late.deliveryFrame)
        try await ledger.commit(late, now: 32)
        let remaining = await ledger.snapshot(now: 32)
        XCTAssertNil(remaining.terminalReason)
        XCTAssertEqual(remaining.activeRequestCount, 1)
        XCTAssertEqual(remaining.cancellationTombstoneCount, 0)
        XCTAssertEqual(remaining.retiredClientCancellationCount, 1)

        let unrelated = try await ledger.prepare(frame: response(#""7""#), direction: .serverToClient, now: 32)
        XCTAssertEqual(unrelated.disposition, .forward)
        XCTAssertNotNil(unrelated.deliveryFrame)
        try await ledger.commit(unrelated, now: 32)
        let final = await ledger.snapshot(now: 32)
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertNil(final.terminalReason)
    }

    func testCancelledIDCannotBeReusedAfterTombstoneExpiry() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        try await forward(cancel("7"), through: ledger, at: 1)
        do {
            _ = try await ledger.prepare(frame: request("7"), direction: .clientToServer, now: 32)
            XCTFail("A previous handler can still settle; same-generation reuse is ambiguous")
        } catch {
            XCTAssertEqual(error as? JSONRPCBridgeLedgerError, .cancelledIDReuse(.clientToServer, .number(7)))
        }
    }

    func testRetirementCapacityFailsClosedRatherThanEvictingAfterExpiry() async throws {
        let ledger = JSONRPCBridgeLedger(configuration: .init(maximumCancellationTombstones: 1))
        _ = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        try await forward(cancel("7"), through: ledger, at: 1)
        try await forward(request("8"), through: ledger, at: 32)
        do {
            try await forward(cancel("8"), through: ledger, at: 32)
            XCTFail("Retention must never silently evict an older cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCBridgeLedgerError, .tombstoneCapacityExceeded(1))
        }
    }

    func testNewBackendGenerationAllowsPreviouslyCancelledID() async throws {
        let ledger = JSONRPCBridgeLedger(configuration: .init(maximumCancellationTombstones: 1))
        let oldGeneration = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        try await forward(cancel("7"), through: ledger, at: 1)
        let newGeneration = try await ledger.beginConnection()
        XCTAssertEqual(newGeneration, oldGeneration + 1)
        let reset = await ledger.snapshot(now: 2)
        XCTAssertEqual(reset.retiredClientCancellationCount, 0)
        try await forward(request("7"), through: ledger, at: 2)
        let delivered = try await ledger.prepare(frame: response("7"), direction: .serverToClient, now: 2)
        XCTAssertEqual(delivered.disposition, .forward)
        try await ledger.commit(delivered, now: 2)
        try await forward(request("8"), through: ledger, at: 2)
        try await forward(cancel("8"), through: ledger, at: 2)
    }

    func testNewBackendGenerationPreservesHostSideAbandonedTombstone() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let accepted = try await ledger.prepare(frame: request("7"), direction: .serverToClient, now: 0)
        try await ledger.commit(accepted, now: 0)
        let terminal = await ledger.recordConnectionFailure("backend_closed", now: 1)
        XCTAssertFalse(terminal)
        _ = try await ledger.beginConnection()
        let lateHostResponse = try await ledger.prepare(frame: response("7"), direction: .clientToServer, now: 2)
        XCTAssertEqual(lateHostResponse.disposition, .discardCancelledResponse)
        try await ledger.commit(lateHostResponse, now: 2)
        let snapshot = await ledger.snapshot(now: 2)
        XCTAssertNil(snapshot.terminalReason)
        XCTAssertEqual(snapshot.cancellationTombstoneCount, 1)
        XCTAssertEqual(snapshot.retiredClientCancellationCount, 0)
        XCTAssertEqual(snapshot.retiredServerCancellationCount, 1)
        let expiredHostResponse = try await ledger.prepare(frame: response("7"), direction: .clientToServer, now: 32)
        XCTAssertEqual(expiredHostResponse.disposition, .discardCancelledResponse)
        try await ledger.commit(expiredHostResponse, now: 32)
        let expired = await ledger.snapshot(now: 32)
        XCTAssertNil(expired.terminalReason)
        XCTAssertEqual(expired.cancellationTombstoneCount, 0)
        XCTAssertEqual(expired.retiredServerCancellationCount, 1)
    }

    func testUnknownCancellationDoesNotAuthorizeUnknownResponse() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(cancel("7"), through: ledger, at: 1)
        do {
            _ = try await ledger.prepare(frame: response("7"), direction: .serverToClient, now: 32)
            XCTFail("Unowned IDs must not be blanket-discarded")
        } catch {
            XCTAssertEqual(error as? JSONRPCBridgeLedgerError, .unknownResponse(.serverToClient, .number(7)))
        }
    }

    func testOldGenerationReplyCannotWriteOrRetireReusedCurrentRequest() async throws {
        let ledger = JSONRPCBridgeLedger()
        let oldGeneration = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        try await forward(cancel("7"), through: ledger, at: 1)
        let newGeneration = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 32)
        let writes = CancellationBridgeWrites()
        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response("7"),
                direction: .serverToClient,
                ledger: ledger,
                expectedConnectionGeneration: oldGeneration,
                now: 32
            ) { frame in await writes.record(frame) }
            XCTFail("An old backend response cannot borrow a reused current-generation ID")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCBridgeLedgerError,
                .staleConnectionGeneration(expected: oldGeneration, actual: newGeneration)
            )
        }
        let staleWrites = await writes.snapshot()
        XCTAssertEqual(staleWrites, [])
        let stillActive = await ledger.snapshot(now: 32)
        XCTAssertEqual(stillActive.activeRequestCount, 1)
        XCTAssertNil(stillActive.terminalReason)
        _ = try await JSONRPCBridgeDelivery.forward(
            frame: response("7"),
            direction: .serverToClient,
            ledger: ledger,
            expectedConnectionGeneration: newGeneration,
            now: 32
        ) { frame in await writes.record(frame) }
        let freshWrites = await writes.snapshot()
        XCTAssertEqual(freshWrites.count, 1)
        let final = await ledger.snapshot(now: 32)
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertNil(final.terminalReason)
    }

    func testOldGenerationTerminalControlCannotTerminalizeCurrentWork() async throws {
        let ledger = JSONRPCBridgeLedger()
        let oldGeneration = try await ledger.beginConnection()
        let newGeneration = try await ledger.beginConnection()
        try await forward(request("7"), through: ledger, at: 0)
        do {
            _ = try await ledger.terminalizeConnection(
                reason: "stale_backend_terminate",
                expectedConnectionGeneration: oldGeneration
            )
            XCTFail("A stale terminal control must not poison the next backend generation")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCBridgeLedgerError,
                .staleConnectionGeneration(expected: oldGeneration, actual: newGeneration)
            )
        }
        let active = await ledger.snapshot(now: 0)
        XCTAssertNil(active.terminalReason)
        XCTAssertEqual(active.activeRequestCount, 1)
        let preparedResponse = try await ledger.prepare(
            frame: response("7"),
            direction: .serverToClient,
            expectedConnectionGeneration: newGeneration,
            now: 0
        )
        try await ledger.commit(preparedResponse, now: 0)
        let final = await ledger.snapshot(now: 0)
        XCTAssertNil(final.terminalReason)
        XCTAssertEqual(final.activeRequestCount, 0)
    }

    func testLateServerCancelledResponsePreservesUnrelatedExactStringIDAfterExpiry() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(request("7"), direction: .serverToClient, through: ledger, at: 0)
        try await forward(request(#""7""#), direction: .serverToClient, through: ledger, at: 0)
        try await forward(cancel("7"), direction: .serverToClient, through: ledger, at: 1)
        let late = try await ledger.prepare(frame: response("7"), direction: .clientToServer, now: 32)
        XCTAssertEqual(late.disposition, .discardCancelledResponse)
        XCTAssertNil(late.deliveryFrame)
        try await ledger.commit(late, now: 32)
        let remaining = await ledger.snapshot(now: 32)
        XCTAssertNil(remaining.terminalReason)
        XCTAssertEqual(remaining.activeRequestCount, 1)
        let unrelated = try await ledger.prepare(frame: response(#""7""#), direction: .clientToServer, now: 32)
        XCTAssertEqual(unrelated.disposition, .forward)
        try await ledger.commit(unrelated, now: 32)
        let final = await ledger.snapshot(now: 32)
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertNil(final.terminalReason)
    }

    func testLateServerCancelledResponseSurvivesBackendRotation() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(request("7"), direction: .serverToClient, through: ledger, at: 0)
        try await forward(cancel("7"), direction: .serverToClient, through: ledger, at: 1)
        _ = try await ledger.beginConnection()
        try await forward(request(#""7""#), through: ledger, at: 2)
        let late = try await ledger.prepare(frame: response("7"), direction: .clientToServer, now: 32)
        XCTAssertEqual(late.disposition, .discardCancelledResponse)
        try await ledger.commit(late, now: 32)
        let remaining = await ledger.snapshot(now: 32)
        XCTAssertNil(remaining.terminalReason)
        XCTAssertEqual(remaining.activeRequestCount, 1)
        let unrelated = try await ledger.prepare(frame: response(#""7""#), direction: .serverToClient, now: 32)
        try await ledger.commit(unrelated, now: 32)
        let final = await ledger.snapshot(now: 32)
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertNil(final.terminalReason)
    }

    func testServerCancelledIDCannotBeReusedAfterExpiryOrBackendRotation() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        try await forward(request("7"), direction: .serverToClient, through: ledger, at: 0)
        try await forward(cancel("7"), direction: .serverToClient, through: ledger, at: 1)
        _ = try await ledger.beginConnection()
        do {
            _ = try await ledger.prepare(frame: request("7"), direction: .serverToClient, now: 32)
            XCTFail("The previous host handler can still settle after the backend rotates")
        } catch {
            XCTAssertEqual(error as? JSONRPCBridgeLedgerError, .cancelledIDReuse(.serverToClient, .number(7)))
        }
    }

    func testHostRetirementSharesCapacityAndSurvivesBackendReset() async throws {
        let ledger = JSONRPCBridgeLedger(configuration: .init(maximumCancellationTombstones: 1))
        _ = try await ledger.beginConnection()
        try await forward(request("7"), direction: .serverToClient, through: ledger, at: 0)
        try await forward(cancel("7"), direction: .serverToClient, through: ledger, at: 1)
        let retained = await ledger.snapshot(now: 32)
        XCTAssertEqual(retained.cancellationTombstoneCount, 0)
        XCTAssertEqual(retained.retiredServerCancellationCount, 1)
        _ = try await ledger.beginConnection()
        try await forward(request("8"), through: ledger, at: 32)
        do {
            try await forward(cancel("8"), through: ledger, at: 32)
            XCTFail("Backend rotation must not free host retirement capacity or evict it")
        } catch {
            XCTAssertEqual(error as? JSONRPCBridgeLedgerError, .tombstoneCapacityExceeded(1))
        }
        let failed = await ledger.snapshot(now: 32)
        XCTAssertEqual(failed.retiredServerCancellationCount, 1)
        XCTAssertEqual(failed.retiredClientCancellationCount, 0)
        XCTAssertEqual(failed.terminalReason, "cancellation_tombstone_capacity_exceeded")
    }

    private func forward(
        _ frame: Data,
        direction: JSONRPCBridgeDirection = .clientToServer,
        through ledger: JSONRPCBridgeLedger,
        at time: TimeInterval
    ) async throws {
        let prepared = try await ledger.prepare(frame: frame, direction: direction, now: time)
        try await ledger.commit(prepared, now: time)
    }

    private func request(_ id: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/list\",\"params\":{}}".utf8)
    }

    private func cancel(_ id: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}".utf8)
    }

    private func response(_ id: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{}}".utf8)
    }
}

private actor CancellationBridgeWrites {
    private var frames: [Data] = []
    func record(_ frame: Data) {
        frames.append(frame)
    }

    func snapshot() -> [Data] {
        frames
    }
}
