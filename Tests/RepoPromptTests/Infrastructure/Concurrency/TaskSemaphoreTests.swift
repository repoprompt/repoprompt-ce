import Foundation
@testable import RepoPromptApp
import XCTest

final class TaskSemaphoreTests: XCTestCase {
    func testCancellationCompletesAcquireWithoutWaitingForRelease() async throws {
        let semaphore = TaskSemaphore(1)
        let initiallyAcquired = await semaphore.acquire()
        XCTAssertTrue(initiallyAcquired)

        let started = AsyncTestCondition(false)
        let completion = AsyncTestCondition<Bool?>(nil)
        let waiter = Task {
            started.update { $0 = true }
            let acquired = await semaphore.acquire()
            completion.update { $0 = acquired }
            return acquired
        }

        try await started.waitUntil("semaphore waiter started") { $0 }
        waiter.cancel()

        let completionResult = try? await completion.waitUntil(
            "cancelled semaphore waiter completion",
            timeout: 1
        ) { $0 != nil }
        let completedBeforeRelease = completionResult != nil

        if !completedBeforeRelease {
            // Keep a known-bad implementation from leaking a parked task and
            // hanging teardown after the assertion below fails.
            await semaphore.release()
        }

        XCTAssertTrue(completedBeforeRelease)
        let waiterAcquired = await waiter.value
        XCTAssertFalse(waiterAcquired)

        await semaphore.release()

        let followUp = Task { await semaphore.acquire() }
        let followUpAcquired = await followUp.value
        XCTAssertTrue(followUpAcquired)
        await semaphore.release()
    }
}
