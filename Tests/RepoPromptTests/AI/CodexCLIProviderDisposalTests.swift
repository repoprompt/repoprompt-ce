import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexCLIProviderDisposalTests: XCTestCase {
    func testDisposeAwaitsCancelledBridgeTaskCleanup() async {
        let provider = CodexCLIProvider()
        let gate = DisposalGate()
        let bridgeTask = provider.test_registerActiveStreamTask(id: UUID()) {
            Task {
                await withTaskCancellationHandler {
                    await gate.waitForRelease()
                } onCancel: {
                    Task { await gate.markCancelled() }
                }
                await gate.markBridgeFinished()
            }
        }
        XCTAssertNotNil(bridgeTask)

        let disposalTask = Task {
            await provider.dispose()
            await gate.markDisposeReturned()
        }

        await gate.waitForCancellation()
        let returnedBeforeCleanup = await gate.disposeReturned
        XCTAssertFalse(returnedBeforeCleanup)

        await gate.releaseBridge()
        await disposalTask.value
        let bridgeFinished = await gate.bridgeFinished
        XCTAssertTrue(bridgeFinished)
    }

    func testRegistrationAfterDisposeIsRefusedWithoutStartingTask() async {
        let provider = CodexCLIProvider()
        await provider.dispose()
        let invocation = InvocationFlag()

        let task = provider.test_registerActiveStreamTask(id: UUID()) {
            invocation.markInvoked()
            return Task {}
        }

        XCTAssertNil(task)
        XCTAssertFalse(invocation.wasInvoked)
    }
}

private final class InvocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false

    var wasInvoked: Bool {
        lock.withLock { invoked }
    }

    func markInvoked() {
        lock.withLock { invoked = true }
    }
}

private actor DisposalGate {
    private var cancellationObserved = false
    private var released = false
    private(set) var bridgeFinished = false
    private(set) var disposeReturned = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markCancelled() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForCancellation() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseBridge() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markBridgeFinished() {
        bridgeFinished = true
    }

    func markDisposeReturned() {
        disposeReturned = true
    }
}
