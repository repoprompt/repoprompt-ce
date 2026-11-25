import Foundation
import os
import RepoPromptCodeMapCore
import RepoPromptFileSystem
import RepoPromptPersistence
@testable import RepoPromptWorkspaceContext
import XCTest

final class CodeMapArtifactBuildSchedulingTests: XCTestCase {
    func testOwnerFairnessEnqueueOrderAndDemandBurstWithWaiterChanges() async throws {
        let harness = try Harness()
        defer { harness.stop() }
        try await harness.startBlocker()
        let ownerA = UUID()
        let ownerB = UUID()
        let ownerC = UUID()

        let first = try await harness.enqueue("First", owner: ownerA, priority: .demand)
        _ = try await harness.join(first, owner: ownerC, priority: .demand)
        let downgraded = try await harness.enqueue("Downgraded", owner: ownerC, priority: .background)
        let departingDemand = try await harness.join(downgraded, owner: ownerA, priority: .demand)
        try await harness.cancel(departingDemand)
        let second = try await harness.enqueue("Second", owner: ownerA, priority: .demand)
        let peer = try await harness.enqueue("Peer", owner: ownerB, priority: .demand)
        let explicit = try await harness.enqueue("Explicit", owner: ownerC, priority: .explicit)
        let upgraded = try await harness.enqueue("Upgraded", owner: ownerC, priority: .background)
        _ = try await harness.join(upgraded, owner: ownerA, priority: .demand)
        let removed = try await harness.enqueue("Removed", owner: ownerC, priority: .demand)
        try await harness.cancel(removed.request)

        let starts = try await harness.drain()
        XCTAssertEqual(starts.map(\.key), [first, peer, explicit, second, upgraded, downgraded].map(\.input.artifactKey))
        XCTAssertEqual(starts.map(\.owner), [ownerA, ownerB, ownerC, ownerA, ownerA, ownerC])
        XCTAssertEqual(starts.map(\.priority), [.demand, .demand, .explicit, .demand, .demand, .background])
    }

    func testAgedExplicitAndBackgroundStarvationBound() async throws {
        let harness = try Harness()
        defer { harness.stop() }
        try await harness.startBlocker()
        let owner = UUID()
        let background = try await harness.enqueue("Background", owner: owner, priority: .background)
        let demand = try await harness.enqueue("Demand", owner: owner, priority: .demand)
        let oldestExplicit = try await harness.enqueue("OldestExplicit", owner: owner, priority: .explicit)
        let olderExplicit = try await harness.enqueue("OlderExplicit", owner: owner, priority: .explicit)
        let thirdExplicit = try await harness.enqueue("ThirdExplicit", owner: owner, priority: .explicit)
        harness.advanceToPromotionAge()
        let freshExplicit = try await harness.enqueue("FreshExplicit", owner: owner, priority: .explicit)

        let starts = try await harness.drain()
        let expected = [oldestExplicit, olderExplicit, background, thirdExplicit, demand, freshExplicit]
        XCTAssertEqual(starts.map(\.key), expected.map(\.input.artifactKey))
        XCTAssertEqual(starts.map(\.priority), [.explicit, .explicit, .background, .explicit, .demand, .explicit])
        let accounting = await harness.coordinator.accounting()
        XCTAssertEqual(accounting.counters.agedBackgroundAdmissions, 1)
        XCTAssertEqual(accounting.counters.nonBackgroundAdmissionsWhileBackgroundAged, 2)
    }

    func testAdmissionUsesOneBackgroundAgingSnapshot() async throws {
        let harness = try Harness()
        defer { harness.stop() }
        try await harness.startBlocker()
        let owner = UUID()
        let background = try await harness.enqueue("Background", owner: owner, priority: .background)
        let demand = try await harness.enqueue("Demand", owner: owner, priority: .demand)
        harness.crossPromotionAgeOnNextRead()

        let starts = try await harness.drain()
        XCTAssertEqual(starts.map(\.key), [demand, background].map(\.input.artifactKey))
        let accounting = await harness.coordinator.accounting()
        XCTAssertEqual(accounting.counters.nonBackgroundAdmissionsWhileBackgroundAged, 0)
        XCTAssertEqual(accounting.counters.agedBackgroundAdmissions, 1)
    }

    private struct BuildStart {
        let key: CodeMapArtifactKey
        let owner: UUID
        let priority: CodeMapArtifactBuildPriority
    }

    private enum HarnessError: Error {
        case buildFinished
        case unexpectedStoreOperation
        case timedOut(String)
    }

    private struct Request {
        let task: Task<Void, Never>
        let result: OSAllocatedUnfairLock<Result<CodeMapArtifactBuildCoordinatorResult, Error>?>
    }

    private final class Harness {
        private static let promotionAge: UInt64 = 100

        let coordinator: CodeMapArtifactBuildCoordinator
        private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let clock = OSAllocatedUnfairLock(initialState: (now: UInt64(0), step: UInt64(0)))
        private let starts = OSAllocatedUnfairLock(initialState: [BuildStart]())
        private let gate = AsyncStream<Void>.makeStream()
        private var requests: [Request] = []

        init() throws {
            let store = try CodeMapArtifactStore(rootURL: root)
            coordinator = CodeMapArtifactBuildCoordinator(
                artifactStore: CodeMapArtifactStoreClient(
                    lookup: { _ in .miss },
                    insert: { _, _ in throw HarnessError.unexpectedStoreOperation },
                    lease: { _ in throw HarnessError.unexpectedStoreOperation },
                    accounting: { await store.accounting() }
                ),
                locatorStore: GitBlobCodeMapLocatorStoreClient(
                    read: { _ in throw HarnessError.unexpectedStoreOperation },
                    write: { _ in throw HarnessError.unexpectedStoreOperation }
                ),
                builder: CodeMapArtifactBuilderClient(build: { [starts, stream = gate.stream] input, owner, priority in
                    let isBlocker = starts.withLock {
                        $0.append(BuildStart(key: input.artifactKey, owner: owner, priority: priority))
                        return $0.count == 1
                    }
                    if isBlocker {
                        var iterator = stream.makeAsyncIterator()
                        _ = await iterator.next()
                    }
                    // Stop after the scheduler hands work to the builder so no parser or CAS timing affects order.
                    throw HarnessError.buildFinished
                }),
                policy: CodeMapArtifactBuildCoordinatorPolicy(
                    maximumConcurrentBuildCount: 1,
                    maximumConsecutiveDemandAdmissions: 2,
                    agePromotionNanoseconds: Self.promotionAge,
                    backgroundAgePromotionNanoseconds: Self.promotionAge,
                    maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: 2
                ),
                clock: CodeMapArtifactBuildCoordinatorClock { [clock] in
                    clock.withLock { state in
                        let now = state.now
                        state.now += state.step
                        state.step = 0
                        return now
                    }
                }
            )
        }

        func startBlocker() async throws {
            let input = try makeInput("Blocker")
            start(input, owner: UUID(), priority: .background)
            try await waitForState("first build entered the gate") { _ in
                self.starts.withLock { $0.count } == 1
            }
        }

        func enqueue(
            _ name: String,
            owner: UUID,
            priority: CodeMapArtifactBuildPriority
        ) async throws -> (input: CodeMapArtifactBuildInput, request: Request) {
            let input = try makeInput(name)
            let expectedQueued = await coordinator.accounting().queuedBuildCount + 1
            let task = start(input, owner: owner, priority: priority)
            try await waitForState("queued \(name)") { $0.queuedBuildCount == expectedQueued }
            return (input, task)
        }

        func join(
            _ flight: (input: CodeMapArtifactBuildInput, request: Request),
            owner: UUID,
            priority: CodeMapArtifactBuildPriority
        ) async throws -> Request {
            let expectedWaiters = await coordinator.accounting().waiterCount + 1
            let task = start(flight.input, owner: owner, priority: priority)
            try await waitForState("waiter joined queued build") { $0.waiterCount == expectedWaiters }
            return task
        }

        func cancel(_ request: Request) async throws {
            request.task.cancel()
            try await waitForState("waiter cancelled") { _ in request.result.withLock { $0 != nil } }
            guard case let .failure(error)? = request.result.withLock({ $0 }), error is CancellationError else {
                return XCTFail("Expected cancelled request to settle with CancellationError")
            }
        }

        func advanceToPromotionAge() {
            clock.withLock { $0.now = Self.promotionAge }
        }

        func crossPromotionAgeOnNextRead() {
            clock.withLock { $0 = (Self.promotionAge - 1, 1) }
        }

        func drain() async throws -> [BuildStart] {
            gate.continuation.finish()
            try await waitForState("queue drained and waiters settled") { accounting in
                accounting.activeFlightCount == 0 && self.requests.allSatisfy { $0.result.withLock { $0 != nil } }
            }
            for request in requests where !request.task.isCancelled {
                guard case let .failure(error)? = request.result.withLock({ $0 }),
                      case HarnessError.buildFinished = error
                else {
                    XCTFail("Expected admitted request to reach the gated builder")
                    continue
                }
            }
            return starts.withLock { Array($0.dropFirst()) }
        }

        func stop() {
            requests.forEach { $0.task.cancel() }
            gate.continuation.finish()
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        private func start(
            _ input: CodeMapArtifactBuildInput,
            owner: UUID,
            priority: CodeMapArtifactBuildPriority
        ) -> Request {
            let result = OSAllocatedUnfairLock<Result<CodeMapArtifactBuildCoordinatorResult, Error>?>(initialState: nil)
            let task = Task { [coordinator] in
                do {
                    let resolution = try await coordinator.resolve(
                        .init(ownerID: owner, priority: priority, target: .source(input))
                    )
                    result.withLock { $0 = .success(resolution) }
                } catch {
                    result.withLock { $0 = .failure(error) }
                }
            }
            let request = Request(task: task, result: result)
            requests.append(request)
            return request
        }

        private func waitForState(
            _ description: String,
            _ predicate: (CodeMapArtifactBuildCoordinatorAccounting) -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            repeat {
                if await predicate(coordinator.accounting()) { return }
                try await Task.sleep(for: .milliseconds(5))
            } while clock.now < deadline
            throw HarnessError.timedOut(description)
        }

        private func makeInput(_ name: String) throws -> CodeMapArtifactBuildInput {
            let data = Data("public struct \(name) {}\n".utf8)
            let fingerprint = FileContentFingerprint(
                deviceID: 1, fileNumber: 2, byteSize: Int64(data.count),
                modificationSeconds: 3, modificationNanoseconds: 4,
                statusChangeSeconds: 5, statusChangeNanoseconds: 6
            )
            let source = CodeMapSourceSnapshot(validatedContent: ValidatedRawFileContentSnapshot(
                data: data, modificationDate: fingerprint.modificationDate, fingerprint: fingerprint
            ))
            return try CodeMapArtifactBuildInput(source: source, language: .swift)
        }
    }
}
