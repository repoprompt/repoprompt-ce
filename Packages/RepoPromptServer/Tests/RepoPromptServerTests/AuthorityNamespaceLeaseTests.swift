import Foundation
import RepoPromptRuntimeModel
@testable import RepoPromptServerHost
import XCTest

@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class AuthorityNamespaceLeaseTests: XCTestCase {
    func testReservedDesktopAuthorityRootAndAliasAreRejectedForBothServingModes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let reserved = base.appendingPathComponent("AgentAuthority", isDirectory: true)
        let alias = base.appendingPathComponent("DesktopAlias", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: reserved)
        defer { try? FileManager.default.removeItem(at: base) }

        for mode in [RepoPromptAuthorityServingMode.server, .directHeadless] {
            XCTAssertThrowsError(try AuthorityNamespaceDescriptor(
                storageRoot: alias.path,
                databasePath: alias.appendingPathComponent("repoprompt.sqlite").path,
                profile: "test",
                servingMode: mode,
                reservedDesktopAuthorityRoots: [reserved.path]
            )) { error in
                XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityPurposeMismatch)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: reserved.appendingPathComponent("repoprompt.sqlite").path))
    }

    func testDecodedDescriptorRevalidatesCanonicalNamespaceIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let encoded = try JSONEncoder().encode(fixture.descriptor)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["namespaceID"] = String(repeating: "0", count: 64)
        let forged = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(AuthorityNamespaceDescriptor.self, from: forged))
    }

    func testSameProcessContentionFailsBeforeStoreOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try AuthorityNamespaceLease.acquire(fixture.descriptor).lease
        defer { first.release() }
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(fixture.descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
    }

    func testSymlinkAliasUsesSameNamespaceIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        FileManager.default.createFile(atPath: fixture.databasePath, contents: Data())
        let aliasRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: aliasRoot) }
        let alias = try AuthorityNamespaceDescriptor(
            storageRoot: aliasRoot.path,
            databasePath: aliasRoot.appendingPathComponent("state.sqlite").path,
            profile: "test",
            servingMode: .server
        )
        XCTAssertEqual(alias.namespaceID, fixture.descriptor.namespaceID)
        let lease = try AuthorityNamespaceLease.acquire(fixture.descriptor).lease
        defer { lease.release() }
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(alias))
    }

    func testUnsafeLockModeFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        FileManager.default.createFile(atPath: fixture.descriptor.leasePath, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.descriptor.leasePath)
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(fixture.descriptor))
    }

    func testUnsupportedLockingFilesystemProbeFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(
            try AuthorityNamespaceLease.acquire(
                fixture.descriptor,
                localFilesystemProbe: { _ in false }
            )
        ) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.descriptor.leasePath))
    }

    func testSecondProcessContentionFails() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        FileManager.default.createFile(atPath: fixture.descriptor.leasePath, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.descriptor.leasePath
        )

        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("python3 is required for the second-process lease fixture")
        }
        let process = Process()
        let ready = Pipe()
        process.executableURL = python
        process.arguments = [
            "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'r+b'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)",
            fixture.descriptor.leasePath
        ]
        process.standardOutput = ready
        process.standardError = Pipe()
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let line = ready.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "ready\n")
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(fixture.descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
    }

    func testStaleOwnerIsReportedAndReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("stale".utf8).write(to: URL(fileURLWithPath: fixture.descriptor.ownerPath))
        let acquisition = try AuthorityNamespaceLease.acquire(fixture.descriptor)
        XCTAssertTrue(acquisition.recoveredStaleOwner)
        XCTAssertNoThrow(try JSONDecoder().decode(
            AuthorityNamespaceOwner.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixture.descriptor.ownerPath))
        ))
        acquisition.lease.release()
    }

    func testHostPublishesStaleOwnerDiagnosticAndMetric() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("stale".utf8).write(to: URL(fileURLWithPath: fixture.descriptor.ownerPath))
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: fixture.descriptor)
        )
        let observation = await host.startupObservation()
        XCTAssertEqual(observation.diagnosticCodes, ["stale_owner_recovered"])
        XCTAssertEqual(observation.staleOwnerRecoveries, 1)
        let report = await host.shutdown(reason: "test")
        XCTAssertTrue(report.clean)
    }

    func testShortDeadlineReportsUncleanAndReleasesLeaseAfterClosingStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: fixture.descriptor)
        )
        let capability = await host.mutationGate.capability()
        let mutation = Task {
            try await capability.perform {
                try await Task.sleep(for: .milliseconds(200))
                return 1
            }
        }
        while await host.mutationGate.snapshot().inFlightMutations == 0 {
            await Task.yield()
        }
        let report = await host.shutdown(reason: "deadline-test", deadline: .milliseconds(10))
        XCTAssertFalse(report.clean)
        XCTAssertTrue(report.drainTimedOut)
        XCTAssertTrue(report.mutationDrainTimedOut)
        XCTAssertTrue(report.budgetExhausted)
        XCTAssertGreaterThanOrEqual(report.elapsed, .milliseconds(5))
        XCTAssertFalse(report.leaseReleased)
        XCTAssertNotEqual(report.actions.last, .leaseReleased)
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(fixture.descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
        _ = try? await mutation.value
        await host.forceCleanupAfterFailedShutdownForTesting()
        let reacquired = try AuthorityNamespaceLease.acquire(fixture.descriptor).lease
        reacquired.release()
    }

    private struct Fixture {
        let root: URL
        let databasePath: String
        let descriptor: AuthorityNamespaceDescriptor

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databasePath = root.appendingPathComponent("state.sqlite").path
            descriptor = try AuthorityNamespaceDescriptor(
                storageRoot: root.path,
                databasePath: databasePath,
                profile: "test",
                servingMode: .server
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
