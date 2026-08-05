import Foundation
@testable import RepoPromptApp
import XCTest

final class AsyncMutexTests: XCTestCase {
    func testCancelledTaskCannotAcquireUnlockedMutex() async throws {
        let mutex = AsyncMutex()
        let taskAcquired = await Task {
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
}
