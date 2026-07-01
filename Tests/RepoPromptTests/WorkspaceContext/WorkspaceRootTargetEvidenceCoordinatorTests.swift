import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRootTargetEvidenceCoordinatorTests: XCTestCase {
    func testEightCompatibleWaitersShareOneEvidenceCommandSetAndTerminalResultIsNotCached() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let commands = TargetEvidenceCommandCounter()
        let gate = TargetEvidenceTestGate()
        let weakHandle = WeakTargetEvidenceHandleBox()
        let key = Self.flightKey(suffix: "eight-waiters")
        let producer: WorkspaceRootTargetEvidenceCoordinator.Producer = { _, context in
            await commands.recordCommandSet(attempt: context.attemptIndex)
            await gate.wait()
            let handle = TargetEvidenceTestHandle()
            weakHandle.store(handle)
            return .sealed(handle: handle, authoritySnapshotIdentity: Data("authority".utf8))
        }

        let tasks = (0 ..< 8).map { _ in
            Task {
                try await coordinator.claim(for: key, producer: producer)
            }
        }
        await assertEventually {
            let diagnostics = await coordinator.diagnosticsSnapshot()
            return diagnostics.joinedWaiterCount == 7
        }
        await gate.open()

        var claims: [WorkspaceRootTargetEvidenceClaim] = []
        for task in tasks {
            try await claims.append(task.value)
        }
        let handleIDs = claims.compactMap { claim in
            claim.handle(as: TargetEvidenceTestHandle.self).map(ObjectIdentifier.init)
        }
        XCTAssertEqual(handleIDs.count, 8)
        XCTAssertEqual(Set(handleIDs).count, 1)
        let firstCommandSnapshot = await commands.snapshot()
        XCTAssertEqual(firstCommandSnapshot, .init(delta: 1, index: 1, status: 1, attempts: [0]))

        let lateClaim = try await coordinator.claim(for: key) { _, context in
            await commands.recordCommandSet(attempt: context.attemptIndex)
            XCTFail("A late compatible waiter must join the sealed flight")
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: Data("authority".utf8)
            )
        }
        var lateHandle: TargetEvidenceTestHandle? = try XCTUnwrap(
            lateClaim.handle(as: TargetEvidenceTestHandle.self)
        )
        XCTAssertEqual(lateHandle.map(ObjectIdentifier.init), handleIDs.first)
        lateHandle = nil
        let lateCommandSnapshot = await commands.snapshot()
        XCTAssertEqual(lateCommandSnapshot.delta, 1)

        for claim in claims {
            await claim.release()
            XCTAssertNil(claim.handle(as: TargetEvidenceTestHandle.self))
        }
        let retainedDiagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(retainedDiagnostics.activeFlightCount, 1)
        await lateClaim.release()
        await assertEventually {
            await coordinator.diagnosticsSnapshot().activeFlightCount == 0 && weakHandle.isEmpty
        }

        let secondGate = TargetEvidenceTestGate(isOpen: true)
        let secondClaim = try await coordinator.claim(for: key) { _, context in
            await commands.recordCommandSet(attempt: context.attemptIndex)
            await secondGate.wait()
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: Data("authority".utf8)
            )
        }
        let secondCommandSnapshot = await commands.snapshot()
        XCTAssertEqual(secondCommandSnapshot, .init(delta: 2, index: 2, status: 2, attempts: [0, 0]))
        await secondClaim.release()
        let diagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.flightsStarted, 2)
        XCTAssertEqual(diagnostics.flightsCleaned, 2)
    }

    func testFirstAuthorityInvalidationRunsOneSealedRetryForAllEightWaiters() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let commands = TargetEvidenceCommandCounter()
        let firstAttemptGate = TargetEvidenceTestGate()
        let key = Self.flightKey(suffix: "retry")
        let authority = Data("same-authority".utf8)
        let producer: WorkspaceRootTargetEvidenceCoordinator.Producer = { _, context in
            await commands.recordCommandSet(attempt: context.attemptIndex)
            if context.attemptIndex == 0 {
                await firstAttemptGate.wait()
                return .authorityInvalidated(
                    originalAuthoritySnapshotIdentity: authority,
                    replacementAuthoritySnapshotIdentity: authority
                )
            }
            XCTAssertEqual(context.requiredAuthoritySnapshotIdentity, authority)
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: authority
            )
        }

        let tasks = (0 ..< 8).map { _ in
            Task {
                try await coordinator.claim(for: key, producer: producer)
            }
        }
        await assertEventually {
            await coordinator.diagnosticsSnapshot().joinedWaiterCount == 7
        }
        await firstAttemptGate.open()

        var claims: [WorkspaceRootTargetEvidenceClaim] = []
        for task in tasks {
            try await claims.append(task.value)
        }
        let commandSnapshot = await commands.snapshot()
        XCTAssertEqual(
            commandSnapshot,
            .init(delta: 2, index: 2, status: 2, attempts: [0, 1])
        )
        let diagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.attemptsStarted, 2)
        XCTAssertEqual(diagnostics.retriesStarted, 1)
        for claim in claims {
            await claim.release()
        }
    }

    func testSnapshotChangeAndSecondInvalidationFailClosed() async throws {
        let changedCoordinator = WorkspaceRootTargetEvidenceCoordinator()
        let changedCommands = TargetEvidenceCommandCounter()
        do {
            _ = try await changedCoordinator.claim(for: Self.flightKey(suffix: "changed")) { _, context in
                await changedCommands.recordCommandSet(attempt: context.attemptIndex)
                return .authorityInvalidated(
                    originalAuthoritySnapshotIdentity: Data("before".utf8),
                    replacementAuthoritySnapshotIdentity: Data("after".utf8)
                )
            }
            XCTFail("Expected changed authority to fail closed")
        } catch let error as WorkspaceRootTargetEvidenceCoordinatorError {
            XCTAssertEqual(error, .authoritySnapshotChanged)
        }
        let changedCommandSnapshot = await changedCommands.snapshot()
        XCTAssertEqual(
            changedCommandSnapshot,
            .init(delta: 1, index: 1, status: 1, attempts: [0])
        )

        let unstableCoordinator = WorkspaceRootTargetEvidenceCoordinator()
        let unstableCommands = TargetEvidenceCommandCounter()
        do {
            _ = try await unstableCoordinator.claim(for: Self.flightKey(suffix: "unstable")) { _, context in
                await unstableCommands.recordCommandSet(attempt: context.attemptIndex)
                let authority = Data("unchanged".utf8)
                return .authorityInvalidated(
                    originalAuthoritySnapshotIdentity: authority,
                    replacementAuthoritySnapshotIdentity: authority
                )
            }
            XCTFail("Expected a second invalidation to fail closed")
        } catch let error as WorkspaceRootTargetEvidenceCoordinatorError {
            XCTAssertEqual(error, .authorityUnstable)
        }
        let unstableCommandSnapshot = await unstableCommands.snapshot()
        XCTAssertEqual(
            unstableCommandSnapshot,
            .init(delta: 2, index: 2, status: 2, attempts: [0, 1])
        )
        let unstableDiagnostics = await unstableCoordinator.diagnosticsSnapshot()
        XCTAssertEqual(unstableDiagnostics.activeFlightCount, 0)
    }

    func testCancellationAndDeadlineDetachOnlyTheirWaiters() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let gate = TargetEvidenceTestGate()
        let commands = TargetEvidenceCommandCounter()
        let key = Self.flightKey(suffix: "waiter-isolation")
        let producer: WorkspaceRootTargetEvidenceCoordinator.Producer = { _, context in
            await commands.recordCommandSet(attempt: context.attemptIndex)
            await gate.wait()
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: Data("authority".utf8)
            )
        }

        let survivor = Task {
            try await coordinator.claim(for: key, producer: producer)
        }
        let cancelled = Task {
            try await coordinator.claim(for: key, producer: producer)
        }
        let deadline = Task {
            try await coordinator.claim(
                for: key,
                deadline: ContinuousClock.now.advanced(by: .milliseconds(25)),
                producer: producer
            )
        }
        await assertEventually {
            await coordinator.diagnosticsSnapshot().joinedWaiterCount == 2
        }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
        do {
            _ = try await deadline.value
            XCTFail("Expected waiter deadline")
        } catch let error as WorkspaceRootTargetEvidenceCoordinatorError {
            XCTAssertEqual(error, .waiterDeadlineExceeded)
        }

        let activeDiagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(activeDiagnostics.activeFlightCount, 1)
        await gate.open()
        let survivorClaim = try await survivor.value
        XCTAssertNotNil(survivorClaim.handle(as: TargetEvidenceTestHandle.self))
        let commandSnapshot = await commands.snapshot()
        XCTAssertEqual(commandSnapshot, .init(delta: 1, index: 1, status: 1, attempts: [0]))
        await survivorClaim.release()
        let diagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.waiterCancellationCount, 1)
        XCTAssertEqual(diagnostics.waiterDeadlineCount, 1)
        XCTAssertEqual(diagnostics.lastWaiterCancellationCount, 0)
    }

    func testLastWaiterCancellationCancelsProducerAndCleansFlight() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let probe = TargetEvidenceCancellationProbe()
        let key = Self.flightKey(suffix: "last-waiter")
        let waiter = Task {
            try await coordinator.claim(for: key) { _, _ in
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    XCTFail("Producer should have been cancelled")
                    return .sealed(
                        handle: TargetEvidenceTestHandle(),
                        authoritySnapshotIdentity: Data()
                    )
                } catch {
                    await probe.markCancelled()
                    throw error
                }
            }
        }
        await assertEventually { await probe.started }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }

        await assertEventually {
            let cancelled = await probe.cancelled
            let activeFlightCount = await coordinator.diagnosticsSnapshot().activeFlightCount
            return cancelled && activeFlightCount == 0
        }
        let diagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.lastWaiterCancellationCount, 1)
        XCTAssertEqual(diagnostics.flightsCleaned, 1)
    }

    func testEarlyClaimReleaseDoesNotReleaseSharedAttemptResourceBeforeSurvivor() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let releases = TargetEvidenceReleaseCounter()
        let gate = TargetEvidenceTestGate()
        let key = Self.flightKey(suffix: "early-claim-release")
        let producer: WorkspaceRootTargetEvidenceCoordinator.Producer = { _, context in
            try await context.retainResource(
                TargetEvidenceTestResource(attempt: context.attemptIndex, releases: releases)
            )
            await gate.wait()
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: Data("authority".utf8)
            )
        }

        let first = Task { try await coordinator.claim(for: key, producer: producer) }
        let second = Task { try await coordinator.claim(for: key, producer: producer) }
        await assertEventually { await coordinator.diagnosticsSnapshot().joinedWaiterCount == 1 }
        await gate.open()
        let firstClaim = try await first.value
        let secondClaim = try await second.value

        await firstClaim.release()
        let releaseCountAfterFirstClaim = await releases.total
        XCTAssertEqual(releaseCountAfterFirstClaim, 0)
        XCTAssertNotNil(secondClaim.handle(as: TargetEvidenceTestHandle.self))

        await secondClaim.release()
        let finalReleaseCount = await releases.total
        let finalReleases = await releases.snapshot()
        XCTAssertEqual(finalReleaseCount, 1)
        XCTAssertEqual(finalReleases, [0: 1])
    }

    func testLastWaiterCancellationReleasesRegisteredAttemptResourceExactlyOnce() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let releases = TargetEvidenceReleaseCounter()
        let probe = TargetEvidenceCancellationProbe()
        let waiter = Task {
            try await coordinator.claim(for: Self.flightKey(suffix: "last-cancel-resource")) { _, context in
                try await context.retainResource(
                    TargetEvidenceTestResource(attempt: context.attemptIndex, releases: releases)
                )
                await probe.markStarted()
                try await Task.sleep(for: .seconds(30))
                return .sealed(
                    handle: TargetEvidenceTestHandle(),
                    authoritySnapshotIdentity: Data("authority".utf8)
                )
            }
        }
        await assertEventually { await probe.started }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        await assertEventually { await releases.total == 1 }
        let releasesAfterCancellation = await releases.snapshot()
        XCTAssertEqual(releasesAfterCancellation, [0: 1])
        await Task.yield()
        let releaseCountAfterYield = await releases.total
        XCTAssertEqual(releaseCountAfterYield, 1)
    }

    func testLastWaiterCancellationJoinsProducerBeforeReleasingAttemptResource() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let ordering = TargetEvidenceCancellationOrderingProbe()
        let waiter = Task {
            try await coordinator.claim(for: Self.flightKey(suffix: "last-cancel-join-order")) {
                _, context in
                try await context.retainResource(
                    TargetEvidenceOrderingResource(ordering: ordering)
                )
                await ordering.markProducerStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .sealed(
                        handle: TargetEvidenceTestHandle(),
                        authoritySnapshotIdentity: Data("authority".utf8)
                    )
                } catch {
                    await ordering.markProducerTerminated()
                    throw error
                }
            }
        }
        await assertEventually { await ordering.producerStarted }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let events = await ordering.events
        let diagnostics = await coordinator.diagnosticsSnapshot()
        XCTAssertEqual(events, [.producerTerminated, .resourceReleased])
        XCTAssertEqual(diagnostics.activeFlightCount, 0)
    }

    func testProducerFailureReleasesRegisteredAttemptResourceExactlyOnce() async {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let releases = TargetEvidenceReleaseCounter()
        do {
            _ = try await coordinator.claim(
                for: Self.flightKey(suffix: "producer-failure-resource")
            ) { _, context in
                try await context.retainResource(
                    TargetEvidenceTestResource(attempt: context.attemptIndex, releases: releases)
                )
                throw TargetEvidenceTestError.producerFailed
            }
            XCTFail("Expected producer failure")
        } catch let error as TargetEvidenceTestError {
            XCTAssertEqual(error, .producerFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let releasesAfterFailure = await releases.snapshot()
        let activeFlightCount = await coordinator.diagnosticsSnapshot().activeFlightCount
        XCTAssertEqual(releasesAfterFailure, [0: 1])
        XCTAssertEqual(activeFlightCount, 0)
    }

    func testRetryReleasesOldAttemptResourceAndFinalClaimReleasesReplacementExactlyOnce() async throws {
        let coordinator = WorkspaceRootTargetEvidenceCoordinator()
        let releases = TargetEvidenceReleaseCounter()
        let authority = Data("retry-authority".utf8)
        let claim = try await coordinator.claim(for: Self.flightKey(suffix: "retry-resource")) {
            _, context in
            try await context.retainResource(
                TargetEvidenceTestResource(attempt: context.attemptIndex, releases: releases)
            )
            if context.attemptIndex == 0 {
                return .authorityInvalidated(
                    originalAuthoritySnapshotIdentity: authority,
                    replacementAuthoritySnapshotIdentity: authority
                )
            }
            XCTAssertEqual(context.requiredAuthoritySnapshotIdentity, authority)
            return .sealed(
                handle: TargetEvidenceTestHandle(),
                authoritySnapshotIdentity: authority
            )
        }

        let releasesBeforeClaimRelease = await releases.snapshot()
        XCTAssertEqual(releasesBeforeClaimRelease, [0: 1])
        await claim.release()
        let releasesAfterClaimRelease = await releases.snapshot()
        XCTAssertEqual(releasesAfterClaimRelease, [0: 1, 1: 1])
    }

    private static func flightKey(suffix: String) -> WorkspaceRootTargetEvidenceFlightKey {
        WorkspaceRootTargetEvidenceFlightKey(
            physicalWorktree: .init(
                canonicalRootPath: "/tmp/repoprompt-target-evidence-\(suffix)",
                deviceID: 11,
                inode: 22,
                canonicalGitDirectoryPath: "/tmp/repoprompt-target-evidence-\(suffix)/.git"
            ),
            gitAuthorityRepositoryIdentity: Data("repository".utf8),
            repositoryRelativeRootPrefix: Data("Sources".utf8),
            reusableSnapshotIdentity: Data("snapshot".utf8),
            catalogPolicyIdentity: Data("catalog".utf8),
            creationCutIdentity: Data("cut".utf8),
            namespaceAcquisitionIdentity: Data("namespace".utf8),
            inventorySchema: 2,
            searchSchema: 2
        )
    }

    private func assertEventually(
        attempts: Int = 2000,
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< attempts {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private final class TargetEvidenceTestHandle: WorkspaceRootTargetEvidenceHandle, @unchecked Sendable {}

private final class WeakTargetEvidenceHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var handle: TargetEvidenceTestHandle?

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle == nil
    }

    func store(_ handle: TargetEvidenceTestHandle) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }
}

private actor TargetEvidenceTestGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }
}

private actor TargetEvidenceCommandCounter {
    struct Snapshot: Equatable {
        let delta: Int
        let index: Int
        let status: Int
        let attempts: [Int]
    }

    private var delta = 0
    private var index = 0
    private var status = 0
    private var attempts: [Int] = []

    func recordCommandSet(attempt: Int) {
        delta += 1
        index += 1
        status += 1
        attempts.append(attempt)
    }

    func snapshot() -> Snapshot {
        Snapshot(delta: delta, index: index, status: status, attempts: attempts)
    }
}

private actor TargetEvidenceCancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor TargetEvidenceCancellationOrderingProbe {
    enum Event: Equatable {
        case producerTerminated
        case resourceReleased
    }

    private(set) var producerStarted = false
    private(set) var events: [Event] = []

    func markProducerStarted() {
        producerStarted = true
    }

    func markProducerTerminated() {
        events.append(.producerTerminated)
    }

    func markResourceReleased() {
        events.append(.resourceReleased)
    }
}

private final class TargetEvidenceOrderingResource: WorkspaceRootTargetEvidenceAttemptResource,
    @unchecked Sendable
{
    private let ordering: TargetEvidenceCancellationOrderingProbe

    init(ordering: TargetEvidenceCancellationOrderingProbe) {
        self.ordering = ordering
    }

    func release() async {
        await ordering.markResourceReleased()
    }
}

private enum TargetEvidenceTestError: Error, Equatable {
    case producerFailed
}

private final class TargetEvidenceTestResource: WorkspaceRootTargetEvidenceAttemptResource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let attempt: Int
    private let releases: TargetEvidenceReleaseCounter
    private var isReleased = false

    init(attempt: Int, releases: TargetEvidenceReleaseCounter) {
        self.attempt = attempt
        self.releases = releases
    }

    func release() async {
        guard markReleased() else { return }
        await releases.record(attempt: attempt)
    }

    private func markReleased() -> Bool {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return false
        }
        isReleased = true
        lock.unlock()
        return true
    }
}

private actor TargetEvidenceReleaseCounter {
    private var releasesByAttempt: [Int: Int] = [:]

    var total: Int {
        releasesByAttempt.values.reduce(0, +)
    }

    func record(attempt: Int) {
        releasesByAttempt[attempt, default: 0] += 1
    }

    func snapshot() -> [Int: Int] {
        releasesByAttempt
    }
}
