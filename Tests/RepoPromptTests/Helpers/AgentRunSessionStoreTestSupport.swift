import Foundation
@testable import RepoPromptApp
import XCTest

func waitForAgentRunSessionStoreWaiter(
    registration: AgentRunSessionStore.Registration,
    expectedCount: Int = 1,
    timeout: TimeInterval = 1.5,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    do {
        try await AsyncTestWait.waitUntil(
            "AgentRunSessionStore waiter count \(expectedCount)",
            timeout: timeout
        ) {
            await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == expectedCount
        }
    } catch {
        let actualCount = await AgentRunSessionStore.shared.test_waiterCount(registration: registration)
        XCTFail(
            "Timed out waiting for AgentRunSessionStore waiter count \(expectedCount); actual=\(actualCount).",
            file: file,
            line: line
        )
        throw error
    }
}
