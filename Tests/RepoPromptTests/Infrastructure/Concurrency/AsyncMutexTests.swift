import Foundation
@testable import RepoPromptApp
import XCTest

final class AsyncMutexTests: XCTestCase {
    func testCancelledTaskCannotAcquireUnlockedMutex() async throws {
        let mutex = AsyncMutex()
        let taskAcquired = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }

            do {
                _ = try await mutex.withLock { true }
                return true
            } catch is CancellationError {
                return false
            }
        }.value

        XCTAssertFalse(taskAcquired)

        let followUpAcquired = try await mutex.withLock { true }
        XCTAssertTrue(followUpAcquired)
    }

    func testCancelledTaskCanAcquireForCleanupAfterCurrentOwnerReleases() async throws {
        let mutex = AsyncMutex()
        let ownerEntered = TestReleaseFence(name: "AsyncMutex owner")

        let owner = Task {
            try await mutex.withLock {
                await ownerEntered.enterAndWaitIgnoringCancellationUntilRelease()
            }
        }
        await ownerEntered.waitUntilEntered()

        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await mutex.withLockIgnoringCancellation { true }
        }
        ownerEntered.release()

        try await owner.value
        let cleanupAcquired = try await cleanup.value
        XCTAssertTrue(cleanupAcquired)
    }
}
