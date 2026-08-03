@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainConnectionCallAdmissionTests: XCTestCase {
    func testRegistryOwnsMonotonicReplacementGenerationsAcrossRemoval() async {
        let registry = MCPDomainConnectionCallAdmissionRegistry()
        let first = MCPDomainConnectionCallLimiters(
            limit: 1,
            controlLimit: 1,
            smallReadLimit: 1,
            gitReadLimit: 1,
            fileSearchLimit: 1
        )
        let connectionID = UUID()
        registry[connectionID] = first
        let firstEntry = registry.entry(for: connectionID)
        XCTAssertEqual(firstEntry?.replacementGeneration, 1)
        XCTAssertTrue(firstEntry?.limiters === first)

        let second = MCPDomainConnectionCallLimiters(
            limit: 2,
            controlLimit: 1,
            smallReadLimit: 1,
            gitReadLimit: 1,
            fileSearchLimit: 1
        )
        registry[connectionID] = second
        let secondEntry = registry.entry(for: connectionID)
        XCTAssertEqual(secondEntry?.replacementGeneration, 2)
        XCTAssertTrue(secondEntry?.limiters === second)

        XCTAssertTrue(registry.removeValue(forKey: connectionID) === second)
        registry[connectionID] = first
        XCTAssertEqual(registry.entry(for: connectionID)?.replacementGeneration, 3)
    }

    func testTentativeCloseRestoresQueuedAdmissionToExactReplacement() async throws {
        let sleepGate = AdmissionSleepGate()
        let original = MCPDomainConnectionCallLimiters(
            limit: 1,
            controlLimit: 1,
            smallReadLimit: 1,
            gitReadLimit: 1,
            fileSearchLimit: 1,
            idleWaitSleep: { duration in try await sleepGate.sleep(duration) }
        )
        let replacement = MCPDomainConnectionCallLimiters(
            limit: 1,
            controlLimit: 1,
            smallReadLimit: 1,
            gitReadLimit: 1,
            fileSearchLimit: 1
        )

        let didClose = await original.closeIfIdle()
        XCTAssertTrue(didClose)
        let retry = Task { await original.admissionRetryReplacement() }
        await Task.yield()
        await original.markTentativeCloseRestored(by: replacement)
        let resolved = await retry.value
        XCTAssertTrue(resolved === replacement)
        let waiterCount = await original.admissionRetryWaiterCountForTesting()
        XCTAssertEqual(waiterCount, 0)
    }
}

private actor AdmissionSleepGate {
    func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
