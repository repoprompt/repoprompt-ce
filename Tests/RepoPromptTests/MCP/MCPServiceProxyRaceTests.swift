@testable import RepoPromptMCP
import XCTest

final class MCPServiceProxyRaceTests: XCTestCase {
    func testEachChildCanWinWithValueOrErrorAndDrainsLosers() async throws {
        let outcomes: [MCPServiceProxyTaskOutcome] = [
            .killSignalWaitCancelled,
            .ppidWatchdogCancelled,
            .transportCompleted
        ]

        for winnerID in outcomes.indices {
            for winnerThrows in [false, true] {
                let probe = MCPProxyRaceProbe(expectedStartCount: outcomes.count)
                let winnerResult: Result<MCPServiceProxyTaskOutcome, Error> = winnerThrows
                    ? .failure(MCPProxyRaceTestError.winner(winnerID))
                    : .success(outcomes[winnerID])
                let operations = outcomes.indices.map { childID in
                    makeOperation(
                        childID: childID,
                        winnerID: winnerID,
                        winnerResult: winnerResult,
                        probe: probe
                    )
                }

                do {
                    let outcome = try await MCPService.awaitFirstProxyOutcome(
                        killSignal: operations[0],
                        watchdog: operations[1],
                        transport: operations[2]
                    )
                    XCTAssertFalse(winnerThrows, "Expected child \(winnerID) to throw")
                    XCTAssertEqual(proxyOutcomeID(outcome), winnerID)
                } catch let error as MCPProxyRaceTestError {
                    XCTAssertTrue(winnerThrows, "Unexpected child error: \(error)")
                    XCTAssertEqual(error, .winner(winnerID))
                }

                let snapshot = await probe.snapshot()
                XCTAssertEqual(snapshot.completed, Set(outcomes.indices))
                XCTAssertEqual(snapshot.cancelled, Set(outcomes.indices.filter { $0 != winnerID }))
            }
        }
    }

    func testRaceDoesNotReturnUntilCancelledLosersComplete() async throws {
        let probe = MCPProxyRaceProbe(expectedStartCount: 3)
        let drainGate = MCPProxyRaceGate()
        let returned = MCPProxyRaceFlag()
        let winnerResult = Result<MCPServiceProxyTaskOutcome, Error>.success(.transportCompleted)
        let operations = (0 ..< 3).map { childID in
            makeOperation(
                childID: childID,
                winnerID: 2,
                winnerResult: winnerResult,
                probe: probe,
                drainGate: drainGate
            )
        }
        let race = Task {
            let outcome = try await MCPService.awaitFirstProxyOutcome(
                killSignal: operations[0],
                watchdog: operations[1],
                transport: operations[2]
            )
            await returned.set()
            return outcome
        }

        await probe.waitUntilCancelled(count: 2)
        let didReturnBeforeLosersCompleted = await returned.value
        XCTAssertFalse(didReturnBeforeLosersCompleted)

        await drainGate.release()
        let outcome = try await race.value
        XCTAssertEqual(proxyOutcomeID(outcome), 2)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.completed, Set(0 ..< 3))
    }

    func testOuterCancellationCancelsAndDrainsAllChildren() async throws {
        let probe = MCPProxyRaceProbe(expectedStartCount: 3)
        let drainGate = MCPProxyRaceGate()
        let returned = MCPProxyRaceFlag()
        let operations = (0 ..< 3).map { childID in
            makeOperation(
                childID: childID,
                winnerID: nil,
                winnerResult: .success(.transportCompleted),
                probe: probe,
                drainGate: drainGate
            )
        }
        let race = Task {
            do {
                let outcome = try await MCPService.awaitFirstProxyOutcome(
                    killSignal: operations[0],
                    watchdog: operations[1],
                    transport: operations[2]
                )
                await returned.set()
                return outcome
            } catch {
                await returned.set()
                throw error
            }
        }

        await probe.waitUntilAllStarted()
        race.cancel()
        await probe.waitUntilCancelled(count: 3)
        let didReturnBeforeChildrenCompleted = await returned.value
        XCTAssertFalse(didReturnBeforeChildrenCompleted)

        await drainGate.release()
        do {
            _ = try await race.value
            XCTFail("Expected outer cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.cancelled, Set(0 ..< 3))
        XCTAssertEqual(snapshot.completed, Set(0 ..< 3))
    }

    func testAlreadyCancelledCallerDoesNotStartChildren() async throws {
        let entryGate = MCPProxyRaceGate()
        let probe = MCPProxyRaceProbe(expectedStartCount: 3)
        let operations = (0 ..< 3).map { childID in
            makeOperation(
                childID: childID,
                winnerID: nil,
                winnerResult: .success(.transportCompleted),
                probe: probe
            )
        }
        let race = Task {
            await entryGate.wait()
            return try await MCPService.awaitFirstProxyOutcome(
                killSignal: operations[0],
                watchdog: operations[1],
                transport: operations[2]
            )
        }

        race.cancel()
        await entryGate.release()

        do {
            _ = try await race.value
            XCTFail("Expected outer cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.started.isEmpty)
        XCTAssertTrue(snapshot.cancelled.isEmpty)
        XCTAssertTrue(snapshot.completed.isEmpty)
    }

    private func makeOperation(
        childID: Int,
        winnerID: Int?,
        winnerResult: Result<MCPServiceProxyTaskOutcome, Error>,
        probe: MCPProxyRaceProbe,
        drainGate: MCPProxyRaceGate? = nil
    ) -> @Sendable () async throws -> MCPServiceProxyTaskOutcome {
        {
            await probe.markStarted(childID)
            await probe.waitUntilAllStarted()
            if childID == winnerID {
                await probe.markCompleted(childID)
                return try winnerResult.get()
            }

            do {
                try await Task.sleep(nanoseconds: UInt64.max)
                throw MCPProxyRaceTestError.loserReturnedWithoutCancellation(childID)
            } catch is CancellationError {
                await probe.markCancelled(childID)
                if let drainGate {
                    await drainGate.wait()
                }
                await probe.markCompleted(childID)
                throw CancellationError()
            }
        }
    }

    private func proxyOutcomeID(_ outcome: MCPServiceProxyTaskOutcome) -> Int {
        switch outcome {
        case .killSignalWaitCancelled:
            0
        case .ppidWatchdogCancelled:
            1
        case .transportCompleted:
            2
        }
    }
}

private enum MCPProxyRaceTestError: Error, Equatable {
    case winner(Int)
    case loserReturnedWithoutCancellation(Int)
}

private actor MCPProxyRaceProbe {
    struct Snapshot {
        let started: Set<Int>
        let cancelled: Set<Int>
        let completed: Set<Int>
    }

    private let expectedStartCount: Int
    private var started: Set<Int> = []
    private var cancelled: Set<Int> = []
    private var completed: Set<Int> = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(expectedStartCount: Int) {
        self.expectedStartCount = expectedStartCount
    }

    func markStarted(_ childID: Int) {
        started.insert(childID)
        guard started.count == expectedStartCount else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilAllStarted() async {
        guard started.count < expectedStartCount else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markCancelled(_ childID: Int) {
        cancelled.insert(childID)
        let ready = cancellationWaiters.filter { cancelled.count >= $0.count }
        cancellationWaiters.removeAll { cancelled.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntilCancelled(count: Int) async {
        guard cancelled.count < count else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    func markCompleted(_ childID: Int) {
        completed.insert(childID)
    }

    func snapshot() -> Snapshot {
        Snapshot(started: started, cancelled: cancelled, completed: completed)
    }
}

private actor MCPProxyRaceGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MCPProxyRaceFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
