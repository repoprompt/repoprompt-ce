import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPServiceParticipationTests: XCTestCase {
    func testOlderJoinEligibilityCompletionCannotOverrideNewerLeave() async throws {
        let eligibility = EligibilityBarrier()
        let listener = ListenerProbe()
        let service = makeService(listener: listener) { windowID in
            await eligibility.request(windowID: windowID)
        }

        let join = Task { try await service.join(windowID: 1) }
        await eligibility.waitUntilRequestCount(1)
        let leave = Task { await service.leave(windowID: 1) }
        await eligibility.waitUntilRequestCount(2)

        await eligibility.resumeRequest(at: 1, eligible: false)
        await leave.value
        await eligibility.resumeRequest(at: 0, eligible: true)
        try await join.value

        let state = await service.currentState()
        let listenerState = await listener.snapshot()
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(listenerState.startCount, 0)
        XCTAssertEqual(listenerState.stopCount, 0)
    }

    func testOlderLeaveEligibilityCompletionCannotStopNewerJoin() async throws {
        let eligibility = EligibilityBarrier()
        let listener = ListenerProbe()
        let service = makeService(listener: listener) { windowID in
            await eligibility.request(windowID: windowID)
        }

        let leave = Task { await service.leave(windowID: 2) }
        await eligibility.waitUntilRequestCount(1)
        let join = Task { try await service.join(windowID: 2) }
        await eligibility.waitUntilRequestCount(2)

        await eligibility.resumeRequest(at: 1, eligible: true)
        try await join.value
        await eligibility.resumeRequest(at: 0, eligible: false)
        await leave.value

        let state = await service.currentState()
        let listenerState = await listener.snapshot()
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(listenerState.startCount, 1)
        XCTAssertEqual(listenerState.stopCount, 0)

        await service.fullShutdown()
    }

    func testStartCompletionReconcilesToNewerLeaveDesiredState() async throws {
        let eligibility = EligibilityState()
        let listener = ListenerProbe(suspendStarts: true)
        let service = makeService(listener: listener) { windowID in
            await eligibility.isEligible(windowID: windowID)
        }

        await eligibility.setEligible(true, windowID: 3)
        let join = Task { try await service.join(windowID: 3) }
        await listener.waitUntilStartCount(1)

        await eligibility.setEligible(false, windowID: 3)
        let leave = Task { await service.leave(windowID: 3) }
        await listener.releaseStarts()

        try await join.value
        await leave.value

        let state = await service.currentState()
        let listenerState = await listener.snapshot()
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(listenerState.startCount, 1)
        XCTAssertEqual(listenerState.stopCount, 1)
    }

    func testForceStopAllowsLaterEligibleJoinToRestart() async throws {
        let eligibility = EligibilityState()
        let listener = ListenerProbe()
        let service = makeService(listener: listener) { windowID in
            await eligibility.isEligible(windowID: windowID)
        }

        await eligibility.setEligible(true, windowID: 4)
        try await service.join(windowID: 4)
        await service.fullShutdown()
        try await service.join(windowID: 4)

        let state = await service.currentState()
        let listenerState = await listener.snapshot()
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(listenerState.startCount, 2)
        XCTAssertEqual(listenerState.fullShutdownCount, 1)

        await service.fullShutdown()
    }

    func testRepeatedJoinRetriesStartFailureWithoutDuplicateRunningStart() async throws {
        let eligibility = EligibilityState()
        let listener = ListenerProbe(failingStartCount: 1)
        let service = makeService(listener: listener) { windowID in
            await eligibility.isEligible(windowID: windowID)
        }

        await eligibility.setEligible(true, windowID: 5)
        do {
            try await service.join(windowID: 5)
            XCTFail("Expected first listener start to fail")
        } catch ListenerProbe.ProbeError.startFailed {
            // Expected.
        }

        try await service.join(windowID: 5)
        try await service.join(windowID: 5)

        let state = await service.currentState()
        let listenerState = await listener.snapshot()
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(listenerState.startCount, 2)

        await service.fullShutdown()
    }

    private func makeService(
        listener: ListenerProbe,
        eligibility: @escaping @Sendable (Int) async -> Bool
    ) -> MCPService {
        let networkManager = ServerNetworkManager(
            runtimeSessionRegistry: MCPRuntimeSessionRegistry(),
            serviceRegistry: MCPServiceRegistry()
        )
        return MCPService(
            networkManager: networkManager,
            listenerOperations: MCPService.ListenerOperations(
                start: { try await listener.start() },
                stop: { await listener.stop() },
                fullShutdown: { await listener.fullShutdown() }
            ),
            participationEligibility: eligibility,
            configureControllerCallbacks: false
        )
    }
}

private actor EligibilityBarrier {
    private struct Request {
        let windowID: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var requests: [Request] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func request(windowID: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            requests.append(Request(windowID: windowID, continuation: continuation))
            let ready = countWaiters.filter { requests.count >= $0.count }
            countWaiters.removeAll { requests.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func resumeRequest(at index: Int, eligible: Bool) {
        requests[index].continuation.resume(returning: eligible)
    }
}

private actor EligibilityState {
    private var eligibleWindowIDs: Set<Int> = []

    func setEligible(_ eligible: Bool, windowID: Int) {
        if eligible {
            eligibleWindowIDs.insert(windowID)
        } else {
            eligibleWindowIDs.remove(windowID)
        }
    }

    func isEligible(windowID: Int) -> Bool {
        eligibleWindowIDs.contains(windowID)
    }
}

private actor ListenerProbe {
    enum ProbeError: Error {
        case startFailed
    }

    struct Snapshot {
        let startCount: Int
        let stopCount: Int
        let fullShutdownCount: Int
    }

    private let suspendStarts: Bool
    private let failingStartCount: Int
    private var startCount = 0
    private var stopCount = 0
    private var fullShutdownCount = 0
    private var startCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var startReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startsReleased = false

    init(suspendStarts: Bool = false, failingStartCount: Int = 0) {
        self.suspendStarts = suspendStarts
        self.failingStartCount = failingStartCount
    }

    func start() async throws {
        startCount += 1
        let ready = startCountWaiters.filter { startCount >= $0.count }
        startCountWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if startCount <= failingStartCount {
            throw ProbeError.startFailed
        }
        guard suspendStarts, !startsReleased else { return }
        await withCheckedContinuation { startReleaseWaiters.append($0) }
    }

    func stop() {
        stopCount += 1
    }

    func fullShutdown() {
        fullShutdownCount += 1
    }

    func waitUntilStartCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startCountWaiters.append((count, continuation))
        }
    }

    func releaseStarts() {
        startsReleased = true
        startReleaseWaiters.forEach { $0.resume() }
        startReleaseWaiters.removeAll()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startCount: startCount,
            stopCount: stopCount,
            fullShutdownCount: fullShutdownCount
        )
    }
}
