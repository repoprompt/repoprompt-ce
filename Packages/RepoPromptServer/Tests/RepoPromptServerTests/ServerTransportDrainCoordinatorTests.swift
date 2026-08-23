import Foundation
import RepoPromptRuntimeModel
@testable import RepoPromptServerExecutable
@testable import RepoPromptServerHost
import XCTest

final class ServerTransportDrainCoordinatorTests: XCTestCase {
    func testUncooperativeListenerIsBoundedAndRetainsAuthorityLease() async throws {
        let coordinator = ServerTransportDrainCoordinator()
        let blocker = UncooperativeTransportBlocker()
        let task = await coordinator.start {
            await blocker.waitIgnoringCancellation()
        }
        while !(await blocker.hasEntered()) {
            await Task.yield()
        }

        task.cancel()
        let settledBeforeRelease = await coordinator.waitForAll(timeout: .zero)
        let activeBeforeRelease = await coordinator.activeTaskCount()
        XCTAssertFalse(settledBeforeRelease)
        XCTAssertEqual(activeBeforeRelease, 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-http-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "http-drain",
            servingMode: .server
        )
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: descriptor)
        )
        let budget = AuthorityHostShutdownBudget(total: .seconds(1))
        _ = await host.beginShutdown(using: budget)
        let report = await host.shutdown(
            reason: "uncooperative-http-listener",
            using: budget,
            externalTransportDrainTimedOut: true
        )

        XCTAssertFalse(report.clean)
        XCTAssertTrue(report.externalTransportDrainTimedOut)
        XCTAssertFalse(report.leaseReleased)
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }

        await blocker.release()
        _ = await task.value
        let settledAfterRelease = await coordinator.waitForAll(timeout: .zero)
        XCTAssertTrue(settledAfterRelease)
        await host.forceCleanupAfterFailedShutdownForTesting()
    }
}

private actor UncooperativeTransportBlocker {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIgnoringCancellation() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
