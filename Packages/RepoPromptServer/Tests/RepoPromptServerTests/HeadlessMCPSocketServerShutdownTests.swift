#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RepoPromptAuthorityAPI
import RepoPromptMCPAdapter
import RepoPromptRuntimeModel
@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
import XCTest

final class HeadlessMCPSocketServerShutdownTests: XCTestCase {
    func testSilentClientIsReleasedBySocketShutdownWithinChildDrainBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let adapter = RepoPromptMCPAdapter(serving: UnusedMCPServing())
        let server = HeadlessMCPSocketServer(socketURL: socketURL, adapter: adapter)
        try await server.start()

        let client = PortablePOSIX.unixStreamSocket()
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { PortablePOSIX.closeDescriptor(client) }
        var address = sockaddr_un()
        XCTAssertTrue(PortablePOSIX.fillUnixAddress(&address, path: socketURL.path))
        XCTAssertEqual(PortablePOSIX.connectUnix(client, &address), 0)

        let clock = ContinuousClock()
        let registrationDeadline = clock.now.advanced(by: .seconds(1))
        while await server.activeClientCount() == 0, clock.now < registrationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let activeClientCount = await server.activeClientCount()
        XCTAssertEqual(activeClientCount, 1)

        let started = clock.now
        let report = await server.stop(clientDrainTimeout: .milliseconds(200))
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(report.clientCount, 1)
        XCTAssertTrue(report.clean)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        let repeatedReport = await server.stop(clientDrainTimeout: .zero)
        XCTAssertEqual(repeatedReport, report)
    }

    func testUncooperativeChildIsForceClosedAndDurablyFencedBeforeLeaseRelease() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rpuc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "uncooperative-child",
            servingMode: .server
        )
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: descriptor)
        )
        let retainedCapability = await host.mutationGate.capability()
        let blocker = UncooperativeChildBlocker()
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let server = HeadlessMCPSocketServer(
            socketURL: socketURL,
            adapter: RepoPromptMCPAdapter(serving: UnusedMCPServing()),
            clientHandlerOverride: { _ in await blocker.waitIgnoringCancellation() }
        )
        try await server.start()

        let client = PortablePOSIX.unixStreamSocket()
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { PortablePOSIX.closeDescriptor(client) }
        var address = sockaddr_un()
        XCTAssertTrue(PortablePOSIX.fillUnixAddress(&address, path: socketURL.path))
        XCTAssertEqual(PortablePOSIX.connectUnix(client, &address), 0)
        let enteredDeadline = ContinuousClock.now + .seconds(1)
        while !(await blocker.hasEntered()), ContinuousClock.now < enteredDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let childEntered = await blocker.hasEntered()
        XCTAssertTrue(childEntered)

        let budget = AuthorityHostShutdownBudget(total: .seconds(1))
        _ = await host.beginShutdown(using: budget)
        let child = await server.stop(
            clientDrainTimeout: .zero,
            forceCloseReapTimeout: .zero
        )
        XCTAssertEqual(child.forceClosedClientCount, 1)
        XCTAssertEqual(child.unreapedClientCount, 1)

        let report = await host.shutdown(
            reason: "uncooperative-child",
            using: budget,
            childDrainTimedOut: true,
            childWorkUnsettled: true
        )
        XCTAssertFalse(report.clean)
        XCTAssertTrue(report.childDrainTimedOut)
        XCTAssertFalse(report.leaseReleased)
        XCTAssertNotEqual(report.actions.last, .leaseReleased)
        XCTAssertTrue(report.actions.contains(.externalCapabilitiesInvalidated))
        XCTAssertFalse(report.actions.contains(.storeClosed))
        do {
            _ = try await retainedCapability.perform { 1 }
            XCTFail("stale child capability unexpectedly reached authority after close")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        }

        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
        await blocker.release()
        await host.forceCleanupAfterFailedShutdownForTesting()
        let reacquired = try AuthorityNamespaceLease.acquire(descriptor).lease
        reacquired.release()
    }
}

private actor UncooperativeChildBlocker {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIgnoringCancellation() async {
        entered = true
        await withCheckedContinuation { self.continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct UnusedMCPServing: RepoPromptMCPServing {
    private enum StubError: Error { case unused }

    func projectSnapshot(id _: UUID) async throws -> ProjectSnapshot { throw StubError.unused }
    func sessionSnapshot(id _: UUID) async throws -> SessionSnapshot { throw StubError.unused }
    func events(after _: ServiceCursor?, limit _: Int) async throws -> EventPage { throw StubError.unused }
    func advertisedToolNames(isRootSession _: Bool) async throws -> Set<String> { [] }

    func invoke(
        toolName _: String,
        argumentsJSON _: Data,
        binding _: AuthorityMCPBinding
    ) async throws -> Data {
        throw StubError.unused
    }
}
