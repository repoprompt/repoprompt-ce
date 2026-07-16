@testable import RepoPromptApp
import XCTest

final class GitProcessAdmissionControllerTests: XCTestCase {
    func testSustainedUserInitiatedTrafficUsesBoundedWeightedFairnessWithoutStarvation() async throws {
        let controller = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
        let blocker = try await controller.acquire(repositoryKey: "repo", priority: .background)
        let order = GitAdmissionPriorityRecorder()
        var tasks: [Task<Void, Error>] = []

        for _ in 0 ..< 12 {
            tasks.append(Task {
                let lease = try await controller.acquire(repositoryKey: "repo", priority: .userInitiatedAuthority)
                await order.record(.userInitiatedAuthority)
                await controller.release(lease)
            })
            try await waitUntil { await controller.snapshot().waiterCount == tasks.count }
        }
        for _ in 0 ..< 6 {
            tasks.append(Task {
                let lease = try await controller.acquire(repositoryKey: "repo", priority: .codemapDemand)
                await order.record(.codemapDemand)
                await controller.release(lease)
            })
            try await waitUntil { await controller.snapshot().waiterCount == tasks.count }
        }
        for _ in 0 ..< 3 {
            tasks.append(Task {
                let lease = try await controller.acquire(repositoryKey: "repo", priority: .background)
                await order.record(.background)
                await controller.release(lease)
            })
            try await waitUntil { await controller.snapshot().waiterCount == tasks.count }
        }

        let cancelled = Task {
            try await controller.acquire(repositoryKey: "repo", priority: .background)
        }
        try await waitUntil { await controller.snapshot().waiterCount == tasks.count + 1 }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation while queued")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { await controller.snapshot().waiterCount == tasks.count }

        await controller.release(blocker)
        for task in tasks {
            try await task.value
        }

        let values = await order.values
        XCTAssertEqual(values.count(where: { $0 == .userInitiatedAuthority }), 12)
        XCTAssertEqual(values.count(where: { $0 == .codemapDemand }), 6)
        XCTAssertEqual(values.count(where: { $0 == .background }), 3)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values.firstIndex(of: .codemapDemand)), 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values.firstIndex(of: .background)), 3)
        XCTAssertLessThanOrEqual(maximumServiceGap(for: .codemapDemand, in: values), 4)
        XCTAssertLessThanOrEqual(maximumServiceGap(for: .background, in: values), 7)

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeLeaseCount, 0)
        XCTAssertEqual(snapshot.waiterCount, 0)
        XCTAssertEqual(snapshot.deadlineWaiterCount, 0)
    }

    func testDeadlineQueueUsesEDFWithRootTieBreakAndDeterministicExpiryCancellation() async throws {
        let manualClock = GitAdmissionManualClock(now: 100)
        let controller = GitProcessAdmissionController(
            globalLimit: 1,
            perRepositoryLimit: 1,
            clock: manualClock.clock
        )
        let blocker = try await controller.acquire(repositoryKey: "repo", priority: .background)
        let order = GitAdmissionOrderRecorder()

        let codemap = admissionTask(controller, priority: .codemapDemand, deadline: nil, label: "codemap", order: order)
        try await waitUntil { await controller.snapshot().waiterCount == 1 }
        let tiedUser = admissionTask(controller, priority: .userInitiatedAuthority, deadline: 150, label: "tied-user", order: order)
        try await waitUntil { await controller.snapshot().waiterCount == 2 }
        let tiedRoot = admissionTask(controller, priority: .rootBootstrap, deadline: 150, label: "root", order: order)
        try await waitUntil { await controller.snapshot().waiterCount == 3 }
        let earlierUser = admissionTask(controller, priority: .userInitiatedAuthority, deadline: 125, label: "early-user", order: order)
        try await waitUntil { await controller.snapshot().waiterCount == 4 }

        await controller.release(blocker)
        _ = try await (codemap.value, tiedUser.value, tiedRoot.value, earlierUser.value)
        let deadlineOrder = await order.values
        XCTAssertEqual(deadlineOrder, ["early-user", "root", "tied-user", "codemap"])

        let secondBlocker = try await controller.acquire(repositoryKey: "repo", priority: .background)
        let expiring = Task {
            try await controller.acquire(
                repositoryKey: "repo",
                priority: .rootBootstrap,
                deadline: GitProcessAdmissionDeadline(uptimeNanoseconds: 175)
            )
        }
        try await waitUntil { await controller.snapshot().deadlineWaiterCount == 1 }
        manualClock.advance(to: 175)
        do {
            _ = try await expiring.value
            XCTFail("Expected deterministic deadline expiry")
        } catch let error as GitProcessAdmissionError {
            XCTAssertEqual(error, .deadlineExceeded)
        }

        let cancelled = Task {
            try await controller.acquire(
                repositoryKey: "repo",
                priority: .userInitiatedAuthority,
                deadline: GitProcessAdmissionDeadline(uptimeNanoseconds: 250)
            )
        }
        try await waitUntil { await controller.snapshot().deadlineWaiterCount == 1 }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued deadline cancellation")
        } catch is CancellationError {
            // Expected.
        }
        manualClock.advance(to: 250)
        await controller.release(secondBlocker)
        try await waitUntil {
            let snapshot = await controller.snapshot()
            return snapshot.activeLeaseCount == 0 && snapshot.waiterCount == 0 && snapshot.deadlineWaiterCount == 0
        }
    }

    func testQueuedRootBootstrapPrecedesCodemapAndNewLowPriorityCannotBypass() async throws {
        let controller = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
        let blocker = try await controller.acquire(repositoryKey: "repo", priority: .background)
        let order = GitAdmissionOrderRecorder()

        let codemap = Task {
            let lease = try await controller.acquire(repositoryKey: "repo", priority: .codemapDemand)
            await order.record("codemap")
            await controller.release(lease)
        }
        try await waitUntil { await controller.snapshot().waiterCount == 1 }
        let root = Task {
            let lease = try await controller.acquire(repositoryKey: "repo", priority: .rootBootstrap)
            await order.record("root")
            await controller.release(lease)
        }
        try await waitUntil { await controller.snapshot().waiterCount == 2 }
        let newerBackground = Task {
            let lease = try await controller.acquire(repositoryKey: "other", priority: .background)
            await order.record("background")
            await controller.release(lease)
        }
        try await waitUntil { await controller.snapshot().waiterCount == 3 }

        await controller.release(blocker)
        _ = try await (root.value, codemap.value, newerBackground.value)

        let values = await order.values
        XCTAssertEqual(values.first, "root")
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeLeaseCount, 0)
        XCTAssertEqual(snapshot.waiterCount, 0)
    }

    func testBoundedQueueCancellationAndIdempotentReleaseDoNotLeakPermits() async throws {
        let controller = GitProcessAdmissionController(
            globalLimit: 1,
            perRepositoryLimit: 1,
            maximumWaiterCount: 1,
            maximumWaitersPerRepository: 1
        )
        let blocker = try await controller.acquire(repositoryKey: "repo")
        let queued = Task {
            try await controller.acquire(repositoryKey: "repo", priority: .background)
        }
        try await waitUntil { await controller.snapshot().waiterCount == 1 }

        do {
            _ = try await controller.acquire(repositoryKey: "other", priority: .rootBootstrap)
            XCTFail("Expected the bounded global queue to reject a second waiter")
        } catch let error as GitProcessAdmissionError {
            XCTAssertEqual(error, .queueFull)
        }

        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Expected queued admission cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { await controller.snapshot().waiterCount == 0 }
        await controller.release(blocker)
        await controller.release(blocker)
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.activeGlobal, 0)
        XCTAssertEqual(snapshot.activeLeaseCount, 0)
    }

    func testBudgetsBoundGlobalAndPerRepositoryConcurrency() async throws {
        let controller = GitProcessAdmissionController(globalLimit: 2, perRepositoryLimit: 1)
        let probe = GitAdmissionProbe()
        let repositories = ["repo-a", "repo-a", "repo-b", "repo-c"]

        let runAdmission: (String) -> Task<Void, Never> = { repository in
            Task {
                do {
                    let lease = try await controller.acquire(repositoryKey: repository)
                    await probe.enterAndWait(repository: repository)
                    await probe.leave(repository: repository)
                    await controller.release(lease)
                } catch {
                    XCTFail("unexpected admission failure: \(error)")
                }
            }
        }

        let firstTask = runAdmission(repositories[0])
        try await AsyncTestWait.waitUntil("repo-a Git permit to be active") {
            await probe.snapshot().activeByRepository["repo-a"] == 1
        }
        let tasks = [firstTask] + repositories.dropFirst().map(runAdmission)

        do {
            try await AsyncTestWait.waitUntil("both global Git permits and repo-a to be active") {
                let snapshot = await probe.snapshot()
                return snapshot.activeGlobal == 2 && snapshot.activeByRepository["repo-a"] == 1
            }
        } catch {
            await probe.releaseAll()
            for task in tasks {
                task.cancel()
                await task.value
            }
            throw error
        }

        var snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.activeGlobal, 2)
        XCTAssertEqual(snapshot.activeByRepository["repo-a"], 1)
        await probe.releaseAll()
        for task in tasks {
            await task.value
        }

        snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.peakGlobal, 2)
        XCTAssertEqual(snapshot.peakByRepository["repo-a"], 1)
        XCTAssertEqual(snapshot.completed, repositories.count)
    }

    func testBoundedOrderedMapPreservesInputOrder() async {
        let values = await BoundedOrderedConcurrentMap.map([0, 1, 2, 3], maxConcurrent: 2) { value in
            try? await Task.sleep(nanoseconds: UInt64((4 - value) * 5_000_000))
            return "value-\(value)"
        }
        XCTAssertEqual(values, ["value-0", "value-1", "value-2", "value-3"])
    }

    func testOptionalLocksClassifierExcludesMutations() {
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["status", "--porcelain=v2"]))
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["diff", "--numstat", "HEAD"]))
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["worktree", "list", "--porcelain"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["worktree", "add", "/tmp/wt"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["switch", "main"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["fetch", "--all"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["merge", "--abort"]))
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool
    ) async throws {
        try await AsyncTestWait.waitUntil(
            "Git process admission state",
            condition: predicate
        )
    }

    private func admissionTask(
        _ controller: GitProcessAdmissionController,
        priority: GitProcessAdmissionPriority,
        deadline: UInt64?,
        label: String,
        order: GitAdmissionOrderRecorder
    ) -> Task<Void, Error> {
        Task {
            let lease = try await controller.acquire(
                repositoryKey: "repo",
                priority: priority,
                deadline: deadline.map(GitProcessAdmissionDeadline.init(uptimeNanoseconds:))
            )
            await order.record(label)
            await controller.release(lease)
        }
    }

    private func maximumServiceGap(
        for priority: GitProcessAdmissionPriority,
        in values: [GitProcessAdmissionPriority]
    ) -> Int {
        let indices = values.indices.filter { values[$0] == priority }
        guard indices.count > 1 else { return values.count }
        return zip(indices, indices.dropFirst()).map { $1 - $0 }.max() ?? 0
    }
}

private actor GitAdmissionOrderRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor GitAdmissionPriorityRecorder {
    private(set) var values: [GitProcessAdmissionPriority] = []

    func record(_ value: GitProcessAdmissionPriority) {
        values.append(value)
    }
}

private final class GitAdmissionManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64
    private var sleepers: [(deadline: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    init(now: UInt64) {
        current = now
    }

    var clock: GitProcessAdmissionClock {
        GitProcessAdmissionClock(
            now: { [weak self] in self?.now ?? 0 },
            sleepUntil: { [weak self] deadline in
                await self?.sleep(until: deadline)
            }
        )
    }

    func advance(to value: UInt64) {
        lock.lock()
        current = max(current, value)
        let ready = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    private var now: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func sleep(until deadline: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if deadline <= current {
                lock.unlock()
                continuation.resume()
            } else {
                sleepers.append((deadline, continuation))
                lock.unlock()
            }
        }
    }
}

private actor GitAdmissionProbe {
    private var activeGlobal = 0
    private var activeByRepository: [String: Int] = [:]
    private var peakGlobal = 0
    private var peakByRepository: [String: Int] = [:]
    private var completed = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait(repository: String) async {
        activeGlobal += 1
        activeByRepository[repository, default: 0] += 1
        peakGlobal = max(peakGlobal, activeGlobal)
        peakByRepository[repository] = max(
            peakByRepository[repository] ?? 0,
            activeByRepository[repository] ?? 0
        )
        if released {
            return
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func leave(repository: String) {
        activeGlobal -= 1
        activeByRepository[repository, default: 1] -= 1
        completed += 1
    }

    func releaseAll() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> (
        activeGlobal: Int,
        activeByRepository: [String: Int],
        peakGlobal: Int,
        peakByRepository: [String: Int],
        completed: Int
    ) {
        (activeGlobal, activeByRepository, peakGlobal, peakByRepository, completed)
    }
}
