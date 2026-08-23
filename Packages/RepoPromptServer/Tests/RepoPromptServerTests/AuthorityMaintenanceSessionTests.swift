import Foundation
import RepoPromptRuntimeModel
@testable import RepoPromptServicePersistence
@testable import RepoPromptServerHost
import XCTest

final class AuthorityMaintenanceSessionTests: XCTestCase {
    func testServingLeaseRejectsMaintenanceBeforeStoreOpenOrMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: fixture.descriptor)
        )
        let evidence = MaintenanceOpenEvidence()

        do {
            _ = try await AuthorityMaintenanceSession.open(
                configuration: .init(namespace: fixture.descriptor),
                storeOpener: { storage in
                    await evidence.recordStoreOpen()
                    return try await SQLiteServiceStore.openForMaintenance(storage: storage)
                }
            )
            XCTFail("maintenance unexpectedly opened while serving held the namespace")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorityHostConflict)
        }

        let storeOpenCount = await evidence.storeOpenCount()
        let store = try await host.storeForRecovery()
        let schemaVersion = try await store.metadata().schemaVersion
        XCTAssertEqual(storeOpenCount, 0)
        XCTAssertEqual(schemaVersion, SchemaV9.version)
        _ = await host.shutdown(reason: "test")
    }

    func testMaintenanceLeaseRejectsServingAndImportsBeforeRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("legacy.json")
        let sessionID = UUID()
        try Data("{\"id\":\"\(sessionID.uuidString)\",\"items\":[]}".utf8).write(to: source)
        let maintenance = try await AuthorityMaintenanceSession.open(
            configuration: .init(namespace: fixture.descriptor)
        )

        do {
            _ = try await RepoPromptAuthorityHostFactory.start(
                configuration: .init(namespace: fixture.descriptor)
            )
            XCTFail("serving unexpectedly opened while maintenance held the namespace")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorityHostConflict)
        }

        let report = try await maintenance.importLegacyJSON(source: source)
        XCTAssertEqual(report.importedSessions, 1)
        let beforeClose = await maintenance.observation()
        XCTAssertEqual(beforeClose.phases, [.idle, .acquiringLease, .openingStore, .ready, .mutating])
        XCTAssertTrue(beforeClose.storeWasOpened)
        XCTAssertFalse(beforeClose.leaseWasReleased)

        try await maintenance.close(clean: true)
        let afterClose = await maintenance.observation()
        XCTAssertEqual(Array(afterClose.phases.suffix(2)), [.closing, .stopped])
        XCTAssertTrue(afterClose.leaseWasReleased)

        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: fixture.descriptor)
        )
        _ = await host.shutdown(reason: "test")
    }

    func testRestoreAcquiresTargetLeaseBeforeAnyStoreOrPublicationWork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let restore = try AuthorityMaintenanceSession.acquireForRestore(
            configuration: .init(namespace: fixture.descriptor)
        )
        let observation = await restore.observation()
        XCTAssertEqual(observation.phases, [.idle, .acquiringLease, .ready])
        XCTAssertFalse(observation.storeWasOpened)
        XCTAssertFalse(observation.leaseWasReleased)

        do {
            _ = try AuthorityMaintenanceSession.acquireForRestore(
                configuration: .init(namespace: fixture.descriptor)
            )
            XCTFail("a second restore must fail before decrypt or target publication")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorityHostConflict)
        }

        try await restore.close(clean: false)
        let reacquired = try AuthorityMaintenanceSession.acquireForRestore(
            configuration: .init(namespace: fixture.descriptor)
        )
        try await reacquired.close(clean: false)
    }

    private struct Fixture {
        let root: URL
        let descriptor: AuthorityNamespaceDescriptor

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rp-maintenance-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            descriptor = try AuthorityNamespaceDescriptor(
                storageRoot: root.path,
                databasePath: root.appendingPathComponent("state.sqlite").path,
                profile: "maintenance-test",
                servingMode: .server
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor MaintenanceOpenEvidence {
    private var count = 0

    func recordStoreOpen() { count += 1 }
    func storeOpenCount() -> Int { count }
}
