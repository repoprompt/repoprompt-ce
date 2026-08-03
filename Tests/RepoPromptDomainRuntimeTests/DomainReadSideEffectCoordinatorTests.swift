import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainReadSideEffectCoordinatorTests: XCTestCase {
    func testEffectsAreRevisionedAndSerializedPerContext() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let recorder = EffectRecorder()

        let first = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "first"
        ) {
            await recorder.append("first")
        }
        let second = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "second"
        ) {
            await recorder.append("second")
        }

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        try await coordinator.drain(handle: handle, effectClass: .selection, through: second.revision)
        let effects = await recorder.snapshot()
        XCTAssertEqual(effects, ["first", "second"])
    }

    func testExactRetryDeduplicatesAndCollisionFailsClosed() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let operationID = UUID()

        let first = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: operationID,
            fingerprint: "same"
        ) {}
        let retry = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: operationID,
            fingerprint: "same"
        ) {
            XCTFail("Deduplicated operation must not execute twice")
        }
        XCTAssertEqual(first, retry)

        do {
            _ = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: operationID,
                fingerprint: "different"
            ) {}
            XCTFail("Expected collision")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .operationCollision)
        }
    }

    func testFailedEffectDoesNotPoisonLaterCalls() async throws {
        enum ExpectedFailure: Error { case failed }
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let recorder = EffectRecorder()

        let failed = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "failed"
        ) {
            throw ExpectedFailure.failed
        }
        do {
            try await coordinator.wait(handle: handle, receipt: failed)
            XCTFail("Expected exact submitter to observe failure")
        } catch is ExpectedFailure {}

        let recovered = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "recovered"
        ) {
            await recorder.append("recovered")
        }
        try await coordinator.wait(handle: handle, receipt: recovered)
        try await coordinator.drain(
            handle: handle,
            effectClass: .selection,
            through: recovered.revision
        )
        let recoveredEffects = await recorder.snapshot()
        XCTAssertEqual(recoveredEffects, ["recovered"])
    }

    func testSameContextSerializesSelectionButDoesNotBlockGitArtifacts() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let gate = AsyncGate()
        let recorder = EffectRecorder()

        let blockedSelection = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "blocked-selection"
        ) {
            try await gate.wait()
            await recorder.append("selection-1")
        }
        while !(await gate.hasEntered()) { await Task.yield() }

        let laterSelection = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "later-selection"
        ) {
            await recorder.append("selection-2")
        }
        let artifact = try await coordinator.submit(
            handle: handle,
            effectClass: .gitArtifacts,
            operationID: UUID(),
            fingerprint: "artifact"
        ) {
            await recorder.append("artifact")
        }
        try await coordinator.wait(handle: handle, receipt: artifact)
        let unblockedEffects = await recorder.snapshot()
        XCTAssertEqual(unblockedEffects, ["artifact"])

        await gate.release()
        try await coordinator.wait(handle: handle, receipt: blockedSelection)
        try await coordinator.wait(handle: handle, receipt: laterSelection)
        let completedEffects = await recorder.snapshot()
        XCTAssertEqual(completedEffects, ["artifact", "selection-1", "selection-2"])
    }

    func testExpiredFailedReceiptAndRetryFailClosed() async throws {
        enum ExpectedFailure: Error { case failed }
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let operationID = UUID()
        let failed = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: operationID,
            fingerprint: "expired-failure"
        ) {
            throw ExpectedFailure.failed
        }

        for index in 0 ..< 40 {
            let receipt = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "advance-\(index)"
            ) {}
            try await coordinator.wait(handle: handle, receipt: receipt)
            await Task.yield()
        }

        do {
            try await coordinator.wait(handle: handle, receipt: failed)
            XCTFail("An expired failure must never normalize to success")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .receiptUnavailable)
        }
        do {
            _ = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: operationID,
                fingerprint: "expired-failure"
            ) {}
            XCTFail("An expired retry must not re-execute")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .receiptUnavailable)
        }
    }

    func testCancellingDrainDoesNotWaitForOrCancelSharedEffect() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let gate = AsyncGate()
        let receipt = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "shared-blocked"
        ) {
            try await gate.wait()
        }
        while !(await gate.hasEntered()) { await Task.yield() }

        let drainer = Task {
            try await coordinator.drain(
                handle: handle,
                effectClass: .selection,
                through: receipt.revision
            )
        }
        await Task.yield()
        drainer.cancel()
        do {
            try await drainer.value
            XCTFail("Expected prompt drain cancellation")
        } catch is CancellationError {}

        let sharedEffectStillBlocked = await gate.hasEntered()
        XCTAssertTrue(sharedEffectStillBlocked, "drain cancellation must not cancel shared work")
        await gate.release()
        try await coordinator.wait(handle: handle, receipt: receipt)
    }

    func testCancellingWaitDoesNotCancelSharedEffect() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let gate = AsyncGate()
        let receipt = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "wait-shared"
        ) {
            try await gate.wait()
        }
        while !(await gate.hasEntered()) { await Task.yield() }

        let waiter = Task {
            try await coordinator.wait(handle: handle, receipt: receipt)
        }
        await Task.yield()
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Expected exact wait cancellation")
        } catch is CancellationError {}

        for _ in 0 ..< 32 {
            if await gate.wasCancelled() { break }
            await Task.yield()
        }
        let sharedEffectWasCancelled = await gate.wasCancelled()
        XCTAssertFalse(sharedEffectWasCancelled, "waiter cancellation must not cancel shared work")

        await gate.release()
        try await coordinator.wait(handle: handle, receipt: receipt)
    }

    func testShutdownRejectsNewEffectsAndCancelsPendingWork() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let gate = AsyncGate()
        let receipt = try await coordinator.submit(
            handle: handle,
            effectClass: .selection,
            operationID: UUID(),
            fingerprint: "pending"
        ) {
            try await gate.wait()
        }
        await coordinator.shutdown()
        do {
            try await coordinator.wait(handle: handle, receipt: receipt)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        do {
            _ = try await coordinator.submit(
                handle: handle,
                effectClass: .selection,
                operationID: UUID(),
                fingerprint: "late"
            ) {}
            XCTFail("Expected stopped coordinator")
        } catch let error as DomainReadSideEffectError {
            XCTAssertEqual(error, .stopped)
        }
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 1,
            mode: .standalone,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeHandle(identity: DomainRuntimeIdentity) -> DomainReadContextHandle {
        DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: UUID(),
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 1,
            contextRevision: 1,
            routingRevision: 1,
            bindingKind: .runScoped(runID: UUID())
        )
    }
}

private actor EffectRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered = false
    private var cancelled = false

    func wait() async throws {
        entered = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func hasEntered() -> Bool { entered }

    func wasCancelled() -> Bool {
        cancelled
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
