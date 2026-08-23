import Foundation
import RepoPromptRuntimeModel
import XCTest
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

final class BackupRestoreCoreTests: XCTestCase {
    func testCreateVerifyAndSameKindRestorePreserveCompleteManifest() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let managedArtifacts = root.appendingPathComponent("artifact-source", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedArtifacts, withIntermediateDirectories: true)
        try Data("artifact payload".utf8).write(to: managedArtifacts.appendingPathComponent("payload.bin"))
        let databaseURL = state.appendingPathComponent("repoprompt.sqlite")
        try Data("hidden durable material".utf8).write(
            to: state.appendingPathComponent(".event-signing-material")
        )
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        let service = StoreMigrationTestSupport.backupService()
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "failed-verify-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "failed-verify-identity-\(UUID().uuidString).txt"
        )
        let archive = root.appendingPathComponent("backup.tar.age")
        let sourceDigest = String(repeating: "1", count: 64)
        let sidecar = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [
                    .init(logicalID: "", url: state),
                    .init(logicalID: "artifacts", url: managedArtifacts),
                ],
                externalAssets: [
                    .init(
                        logicalID: "provider.codex.binary",
                        disposition: .externalOptional,
                        expectedVersion: "fixture",
                        expectedSHA256: String(repeating: "f", count: 64)
                    ),
                ],
                namespaceKind: "server",
                databaseIdentityDigest: sourceDigest
            ),
            store: store
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertNil(sidecar.verification)

        let verified = try await service.verify(archiveURL: archive, identityFileURL: identity)
        let currentEvidence = try await store.migrationSourceEvidence()
        XCTAssertEqual(verified.manifest.source, currentEvidence)
        XCTAssertEqual(
            verified.manifest.assets.filter { $0.disposition == .included }.map(\.archivePath),
            [".event-signing-material", "artifacts/payload.bin", "repoprompt.sqlite"]
        )
        XCTAssertNotNil(verified.sidecar.verification)

        let target = root.appendingPathComponent("restored", isDirectory: true)
        let restoredArtifacts = root.appendingPathComponent("artifact-restored", isDirectory: true)
        let targetDigest = String(repeating: "2", count: 64)
        _ = try await service.prepareRestore(
            .init(
                archiveURL: archive,
                identityFileURL: identity,
                targetRootURL: target,
                targetNamespaceKind: "server",
                targetDatabaseIdentityDigest: targetDigest,
                includedAssetTargetRoots: ["artifacts": restoredArtifacts]
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("repoprompt.sqlite")),
            try Data(contentsOf: databaseURL)
        )
        XCTAssertEqual(
            try Data(contentsOf: restoredArtifacts.appendingPathComponent("payload.bin")),
            Data("artifact payload".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("artifacts").path))
        let request = try JSONDecoder().decode(
            RestoreNamespaceRequestV1.self,
            from: Data(contentsOf: target.appendingPathComponent("restore-request.json"))
        )
        XCTAssertEqual(request.sourceDatabaseIdentityDigest, sourceDigest)
        XCTAssertEqual(request.targetDatabaseIdentityDigest, targetDigest)
        XCTAssertEqual(request.sourceNamespaceKind, request.targetNamespaceKind)
        XCTAssertEqual(request.missingExternalOptionalAssetIDs, ["provider.codex.binary"])
        XCTAssertEqual(request.maintenanceReceipt.source, currentEvidence)
        XCTAssertEqual(request.maintenanceReceipt.archiveSHA256, verified.sidecar.archiveSHA256)
        XCTAssertEqual(request.maintenanceReceipt.manifestSHA256, verified.sidecar.manifestSHA256)
        XCTAssertEqual(
            request.maintenanceReceipt.sidecarSHA256,
            BackupCryptography.sha256(try Data(contentsOf: BackupRestoreService.sidecarURL(for: archive)))
        )
        XCTAssertFalse(request.maintenanceReceipt.verifierFingerprint?.isEmpty ?? true)
        try await store.close(clean: false)
    }

    func testFailedEncryptLeavesNoArchiveOrSidecar() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let archive = root.deletingLastPathComponent().appendingPathComponent("failed-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService(
            envelope: FailingBackupEnvelope(failEncrypt: true)
        )
        do {
            _ = try await service.create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: root)],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "1", count: 64)
                ),
                store: store
            )
            XCTFail("Expected encryption failure")
        } catch is FailingBackupEnvelope.Failure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackupRestoreService.sidecarURL(for: archive).path))
        try await store.close(clean: false)
    }

    func testBackupRefusesInventoryWithoutCheckpointedDatabase() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not the database".utf8).write(to: unrelated.appendingPathComponent("asset"))
        let store = try await SQLiteServiceStore.open(
            storage: .file(state.appendingPathComponent("repoprompt.sqlite").path)
        )
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let archive = root.appendingPathComponent("incomplete.tar.age")
        do {
            _ = try await StoreMigrationTestSupport.backupService().create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: unrelated)],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "1", count: 64)
                ),
                store: store
            )
            XCTFail("Expected incomplete durable inventory refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        try await store.close(clean: false)
    }

    func testCorruptArchiveAndCrossKindRestoreAreRefusedWithoutTargetMutation() async throws {
        let fixture = try await makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bytes = try Data(contentsOf: fixture.archive)
        bytes[0] ^= 0xff
        try bytes.write(to: fixture.archive)
        do {
            _ = try await fixture.service.verify(archiveURL: fixture.archive, identityFileURL: fixture.identity)
            XCTFail("Expected checksum refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
        }

        // Recreate a valid archive, then prove kind refusal occurs before the
        // empty target is created or populated.
        try? FileManager.default.removeItem(at: fixture.archive)
        try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: fixture.archive))
        _ = try await fixture.service.create(request: fixture.request, store: fixture.store)
        let target = fixture.root.appendingPathComponent("wrong-kind")
        do {
            _ = try await fixture.service.prepareRestore(
                .init(
                    archiveURL: fixture.archive,
                    identityFileURL: fixture.identity,
                    targetRootURL: target,
                    targetNamespaceKind: "directHeadless",
                    targetDatabaseIdentityDigest: String(repeating: "2", count: 64)
                )
            )
            XCTFail("Expected cross-kind refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try await fixture.store.close(clean: false)
    }

    func testVerifiedBackupGatesLeaseBoundMigrationToLatest() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try StoreMigrationTestSupport.namespace(root: root)
        try await StoreMigrationTestSupport.makeV6Store(at: URL(fileURLWithPath: namespace.databasePath))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "identity-\(UUID().uuidString).txt"
        )
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
        }
        let archive = root.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService()
        let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
        _ = try await session.createBackup(
            service: service,
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: namespace.namespaceID
            )
        )
        let migrated = try await session.migrate(
            service: service,
            verifiedBackup: archive,
            identityFileURL: identity
        )
        XCTAssertEqual(migrated.schemaVersion, 9)
        let observation = await session.observation()
        XCTAssertTrue(observation.phases.contains(.migrating))
        try await session.close(clean: true)
    }

    func testFailedIdentityVerificationLeavesPendingStoreUntouched() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "source-mismatch-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "source-mismatch-identity-\(UUID().uuidString).txt"
        )
        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("failed-verify-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService(
            envelope: FailingBackupEnvelope(failEncrypt: false)
        )
        _ = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        do {
            _ = try await service.verify(archiveURL: archive, identityFileURL: identity)
            XCTFail("Expected identity-backed decrypt failure")
        } catch is FailingBackupEnvelope.Failure {}
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        try await store.close(clean: false)
    }

    func testMigrationRechecksVerifiedSourceAndPreservesChangedV6Store() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "source-mismatch-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "source-mismatch-identity-\(UUID().uuidString).txt"
        )
        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("source-mismatch-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService()
        _ = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        let verified = try await service.verify(archiveURL: archive, identityFileURL: identity)
        _ = try await store.database.query(
            "UPDATE service_metadata SET next_global_sequence=next_global_sequence+1 WHERE fixed_id=1"
        )
        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: verified.migrationEvidence,
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            )
            XCTFail("Expected source-evidence mismatch")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
        }
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertEqual(metadata.nextGlobalSequence, 2)
        try await store.close(clean: false)
    }

    func testRestoreIdentityRebindRollsBackBeforeCommitAndReplaysAfterCommit() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let injector = PersistenceFaultInjector { point in
            if point == .beforeTransactionCommit { throw InjectedRestoreFailure() }
        }
        var store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            faultInjector: injector,
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let prior = try await store.metadata().storeID
        do {
            _ = try await store.activateRestoredNamespace(
                from: prior,
                backupSequence: 0,
                manifestDigest: String(repeating: "a", count: 64),
                sourceNamespaceKind: "server",
                sourceDatabaseIdentityDigest: sourceDigest,
                targetNamespaceKind: "server",
                targetDatabaseIdentityDigest: targetDigest,
                activationToken: Data(repeating: 7, count: 32),
                instanceID: UUID(),
                maintenanceReceipt: makeTestMaintenanceReceipt(
                    storeID: prior,
                    backupSequence: 0,
                    manifestSHA256: String(repeating: "a", count: 64)
                )
            )
            XCTFail("Expected interruption before restore commit")
        } catch is InjectedRestoreFailure {}
        let rolledBackMetadata = try await store.metadata()
        XCTAssertEqual(rolledBackMetadata.storeID, prior)
        let rolledBackIdentity = try await store.database.query(
            "SELECT database_identity_digest FROM authority_namespace_identity WHERE fixed_id=1"
        ).first?.column("database_identity_digest")?.string
        XCTAssertEqual(rolledBackIdentity, sourceDigest)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let fresh = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: String(repeating: "a", count: 64),
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID(),
            maintenanceReceipt: makeTestMaintenanceReceipt(
                storeID: prior,
                backupSequence: 0,
                manifestSHA256: String(repeating: "a", count: 64)
            )
        )
        let replayed = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: String(repeating: "a", count: 64),
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID(),
            maintenanceReceipt: makeTestMaintenanceReceipt(
                storeID: prior,
                backupSequence: 0,
                manifestSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNotEqual(fresh, prior)
        XCTAssertEqual(replayed, fresh)
        try await store.close(clean: false)
    }

    func testInterruptedLeaseHeldPublicationRemainsFailClosedWithoutActivationRequest() async throws {
        let fixture = try await makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("interrupted-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let namespace = try StoreMigrationTestSupport.namespace(root: target)
        let restore = try AuthorityMaintenanceSession.acquireForRestore(
            configuration: .init(namespace: namespace)
        )
        let service = BackupRestoreService(
            envelope: CopyingBackupEnvelope(),
            toolVersion: "RepoPromptServerTests/1",
            toolDigest: String(repeating: "a", count: 64),
            restorePublicationFaultInjector: { point in
                if point.hasPrefix("after-move:") { throw InjectedRestorePublicationFailure() }
            }
        )
        do {
            _ = try await restore.prepareRestore(
                service: service,
                request: .init(
                    archiveURL: fixture.archive,
                    identityFileURL: fixture.identity,
                    targetRootURL: target,
                    targetNamespaceKind: "server",
                    targetDatabaseIdentityDigest: namespace.namespaceID
                )
            )
            XCTFail("expected interrupted publication")
        } catch is InjectedRestorePublicationFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("restore-incomplete.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("restore-request.json").path))
        try await restore.close(clean: false)

        do {
            _ = try await SQLiteServiceStore.openForServing(
                storage: .file(namespace.databasePath),
                namespaceKind: "server",
                databaseIdentityDigest: namespace.namespaceID
            )
            XCTFail("incomplete publication must fail closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .quiescing)
        }
        try await fixture.store.close(clean: false)
    }

    func testIdentityModeMustBeExactly0600EvenWithNonCryptographicTestEnvelope() async throws {
        let fixture = try await makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for mode: mode_t in [0o400, 0o640, 0o700, 0o1600, 0o2600, 0o4600, 0o6600] {
            XCTAssertEqual(chmod(fixture.identity.path, mode), 0)
            do {
                _ = try await fixture.service.verify(
                    archiveURL: fixture.archive,
                    identityFileURL: fixture.identity
                )
                XCTFail("identity mode \(String(mode, radix: 8)) must be rejected")
            } catch let error as ServiceAPIError {
                XCTAssertEqual(error.code, .invalidRequest)
                XCTAssertFalse(error.message.contains(fixture.identity.path))
            }
        }
        XCTAssertEqual(chmod(fixture.identity.path, 0o600), 0)
        _ = try await fixture.service.verify(
            archiveURL: fixture.archive,
            identityFileURL: fixture.identity
        )
        try await fixture.store.close(clean: false)
    }

    func testEveryNestedRestoreDirectoryBoundaryIsFsyncedBeforePublication() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let nested = state.appendingPathComponent("one/two/three", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested durable payload".utf8).write(to: nested.appendingPathComponent("payload.bin"))
        let store = try await SQLiteServiceStore.open(
            storage: .file(state.appendingPathComponent("repoprompt.sqlite").path)
        )
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: [StoreMigrationTestSupport.defaultRecipient]
        )
        let identity = try StoreMigrationTestSupport.identityFile(in: root)
        let archive = root.appendingPathComponent("nested.tar.age")
        let evidence = RestoreDurabilityEvidence()
        let service = BackupRestoreService(
            envelope: CopyingBackupEnvelope(),
            toolVersion: "RepoPromptServerTests/1",
            toolDigest: String(repeating: "a", count: 64),
            restorePublicationFaultInjector: { point in evidence.record("publish:\(point)") },
            restoreDirectorySyncObserver: { url in evidence.record("sync:\(url.path)") }
        )
        _ = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: state)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        let target = root.appendingPathComponent("restored", isDirectory: true)
        _ = try await service.prepareRestore(.init(
            archiveURL: archive,
            identityFileURL: identity,
            targetRootURL: target,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: String(repeating: "2", count: 64)
        ))

        let events = evidence.values
        let publication = try XCTUnwrap(events.firstIndex(of: "publish:after-incomplete-marker"))
        for suffix in ["/one", "/one/two", "/one/two/three"] {
            let sync = try XCTUnwrap(events.firstIndex(where: {
                $0.hasPrefix("sync:") && $0.hasSuffix(suffix)
            }), "missing successful fsync evidence for \(suffix)")
            XCTAssertLessThan(sync, publication, "\(suffix) was not durable before publication")
        }
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("one/two/three/payload.bin")),
            Data("nested durable payload".utf8)
        )
        try await store.close(clean: false)
    }

    func testMissingOptionalProviderAssetsDisableAndDegradeOnActivation() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        _ = try await store.database.query(
            "INSERT INTO provider_settings(provider_id,schema_version,enabled,revision,updated_at) VALUES('codex',3,1,7,?)",
            [.float(Date().timeIntervalSince1970)]
        )
        _ = try await store.database.query(
            "INSERT INTO provider_connections(provider_id,schema_version,connection_id,authentication_method,state,test_state,key_helper_configured,workload_identity_configured,created_at,updated_at,revision) VALUES('codex',4,'connection','deviceAuth','ready','passed',0,0,?,?,3)",
            [.float(Date().timeIntervalSince1970), .float(Date().timeIntervalSince1970)]
        )
        let prior = try await store.metadata().storeID
        _ = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: String(repeating: "a", count: 64),
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            missingExternalOptionalAssetIDs: [
                "provider.codex.binary",
                "provider.codex.credentials",
                "project-source.git-ssh-key",
            ],
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID(),
            maintenanceReceipt: makeTestMaintenanceReceipt(
                storeID: prior,
                backupSequence: 0,
                manifestSHA256: String(repeating: "a", count: 64)
            )
        )
        let settings = try await store.database.query(
            "SELECT enabled,revision FROM provider_settings WHERE provider_id='codex'"
        ).first
        let connection = try await store.database.query(
            "SELECT state,test_state,detail,revision FROM provider_connections WHERE provider_id='codex'"
        ).first
        XCTAssertEqual(settings?.column("enabled")?.integer, 0)
        XCTAssertEqual(settings?.column("revision")?.integer, 8)
        XCTAssertEqual(connection?.column("state")?.string, "attention")
        XCTAssertEqual(connection?.column("test_state")?.string, "notTested")
        XCTAssertTrue(connection?.column("detail")?.string?.contains("explicit fingerprint revalidation") == true)
        XCTAssertEqual(connection?.column("revision")?.integer, 4)
        try await store.close(clean: false)
    }

    private func makeBackupFixture() async throws -> (
        root: URL,
        archive: URL,
        identity: URL,
        service: BackupRestoreService,
        store: SQLiteServiceStore,
        request: BackupCreateRequest
    ) {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .file(state.appendingPathComponent("repoprompt.sqlite").path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let identity = try StoreMigrationTestSupport.identityFile(in: root)
        let archive = root.appendingPathComponent("backup.tar.age")
        let service = StoreMigrationTestSupport.backupService()
        let request = BackupCreateRequest(
            outputURL: archive,
            recipientsFileURL: recipients,
            roots: [.init(logicalID: "", url: state)],
            namespaceKind: "server",
            databaseIdentityDigest: String(repeating: "1", count: 64)
        )
        _ = try await service.create(request: request, store: store)
        return (root, archive, identity, service, store, request)
    }
}

final class BackupRecipientRotationTests: XCTestCase {
    private func assertServiceError(
        _ code: ServiceErrorCode,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected service error \(code)")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, code)
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
    }

    func testIndependentCustodianRotationRestoreActivationAndRetirementBookkeeping() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let databaseURL = state.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let old = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        let new = "age1pppppppppppppppppppppppppppppppppppppppppppppppppppp"
        let retired = "age1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
        let oldIdentity = try StoreMigrationTestSupport.identityFile(in: root, name: "old-identity.txt", recipient: old)
        let newIdentity = try StoreMigrationTestSupport.identityFile(in: root, name: "new-identity.txt", recipient: new)
        let unrelatedIdentity = try StoreMigrationTestSupport.identityFile(in: root, name: "unrelated-identity.txt", recipient: retired)
        let firstRecipients = try StoreMigrationTestSupport.recipientsFile(in: root, values: [old], name: "old.txt")
        let rotatedRecipients = try StoreMigrationTestSupport.recipientsFile(in: root, values: [old, new], name: "rotated.txt")
        let retiredRecipients = try StoreMigrationTestSupport.recipientsFile(in: root, values: [new], name: "retired.txt")
        let service = StoreMigrationTestSupport.backupService()
        let firstArchive = root.appendingPathComponent("first.tar.age")
        let rotatedArchive = root.appendingPathComponent("rotated.tar.age")
        let retiredArchive = root.appendingPathComponent("retired.tar.age")

        let create: (URL, URL) async throws -> BackupSidecarV1 = { archive, recipients in
            try await service.create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: state)],
                    namespaceKind: "server",
                    databaseIdentityDigest: sourceDigest
                ),
                store: store
            )
        }
        let first = try await create(firstArchive, firstRecipients)
        let rotated = try await create(rotatedArchive, rotatedRecipients)
        let newOnly = try await create(retiredArchive, retiredRecipients)
        XCTAssertEqual(first.recipientFingerprints.count, 1)
        XCTAssertEqual(rotated.recipientFingerprints.count, 2)
        XCTAssertEqual(newOnly.recipientFingerprints.count, 1)
        XCTAssertTrue(Set(first.recipientFingerprints).isSubset(of: Set(rotated.recipientFingerprints)))

        let firstOld = try await service.verify(archiveURL: firstArchive, identityFileURL: oldIdentity)
        XCTAssertEqual(firstOld.sidecar.verification?.verifierFingerprint, first.recipientFingerprints[0])
        await assertServiceError(.invalidRequest) {
            _ = try await service.verify(archiveURL: firstArchive, identityFileURL: newIdentity)
        }
        _ = try await service.verify(archiveURL: rotatedArchive, identityFileURL: oldIdentity)
        let rotatedNew = try await service.verify(archiveURL: rotatedArchive, identityFileURL: newIdentity)
        XCTAssertEqual(Set(rotatedNew.sidecar.verificationHistory?.map(\.verifierFingerprint) ?? []), Set(rotated.recipientFingerprints))
        await assertServiceError(.invalidRequest) {
            _ = try await service.verify(archiveURL: rotatedArchive, identityFileURL: unrelatedIdentity)
        }
        await assertServiceError(.invalidRequest) {
            _ = try await service.verify(archiveURL: retiredArchive, identityFileURL: oldIdentity)
        }
        _ = try await service.verify(archiveURL: retiredArchive, identityFileURL: newIdentity)
        try await store.close(clean: false)

        let target = root.appendingPathComponent("restored", isDirectory: true)
        _ = try await service.prepareRestore(.init(
            archiveURL: retiredArchive,
            identityFileURL: newIdentity,
            targetRootURL: target,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest
        ))
        let request = try JSONDecoder().decode(
            RestoreNamespaceRequestV1.self,
            from: Data(contentsOf: target.appendingPathComponent("restore-request.json"))
        )
        let restored = try await SQLiteServiceStore.openForServing(
            storage: .file(target.appendingPathComponent("repoprompt.sqlite").path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let freshStoreID = try await restored.activateRestoredNamespace(
            from: request.restoredFromStoreID,
            backupSequence: request.backupSequence,
            manifestDigest: request.backupManifestSHA256,
            sourceNamespaceKind: request.sourceNamespaceKind,
            sourceDatabaseIdentityDigest: request.sourceDatabaseIdentityDigest,
            targetNamespaceKind: request.targetNamespaceKind,
            targetDatabaseIdentityDigest: request.targetDatabaseIdentityDigest,
            missingExternalOptionalAssetIDs: request.missingExternalOptionalAssetIDs,
            activationToken: Data(repeating: 9, count: 32),
            instanceID: UUID(),
            maintenanceReceipt: makeTestMaintenanceReceipt(request.maintenanceReceipt)
        )
        XCTAssertNotEqual(freshStoreID, request.restoredFromStoreID)
        let rebound = try await restored.database.query(
            "SELECT namespace_kind,database_identity_digest FROM authority_namespace_identity WHERE fixed_id=1"
        ).first
        XCTAssertEqual(rebound?.column("namespace_kind")?.string, "server")
        XCTAssertEqual(rebound?.column("database_identity_digest")?.string, targetDigest)
        try await restored.close(clean: false)
    }
}

final class RealAgeBackupIntegrationTests: XCTestCase {
    func testPinnedAgePerformsRealOverlapAndRetirementEncryption() async throws {
        let environment = ProcessInfo.processInfo.environment
        let agePath = environment["REPOPROMPT_AGE_EXECUTABLE"] ?? "/usr/local/libexec/repoprompt/age"
        let keygenPath = environment["REPOPROMPT_AGE_KEYGEN_EXECUTABLE"] ?? "/usr/local/libexec/repoprompt/age-keygen"
        guard FileManager.default.isExecutableFile(atPath: agePath),
              FileManager.default.isExecutableFile(atPath: keygenPath)
        else {
            throw XCTSkip("pinned real age and age-keygen executables are unavailable")
        }
        let configuration: AgeRuntimeConfiguration
        do {
            configuration = try .environment(environment)
        } catch {
            throw XCTSkip("pinned age checksum configuration is unavailable")
        }
        let envelope = try AgeBackupEnvelope(configuration: configuration)
        let service = StoreMigrationTestSupport.backupService(envelope: envelope)
        let root = try StoreMigrationTestSupport.temporaryDirectory("real-age")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(
            storage: .file(state.appendingPathComponent("repoprompt.sqlite").path)
        )
        let oldIdentity = root.appendingPathComponent("custodian-old.agekey")
        let newIdentity = root.appendingPathComponent("custodian-new.agekey")
        _ = try run(keygenPath, ["-o", oldIdentity.path])
        _ = try run(keygenPath, ["-o", newIdentity.path])
        XCTAssertEqual(chmod(oldIdentity.path, 0o600), 0)
        XCTAssertEqual(chmod(newIdentity.path, 0o600), 0)
        let oldRecipient = try run(keygenPath, ["-y", oldIdentity.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        let newRecipient = try run(keygenPath, ["-y", newIdentity.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        let overlapRecipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: [oldRecipient, newRecipient],
            name: "overlap-recipients.txt"
        )
        let retiredRecipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: [newRecipient],
            name: "retired-recipients.txt"
        )
        let overlap = root.appendingPathComponent("overlap.tar.age")
        let retired = root.appendingPathComponent("retired.tar.age")
        for (archive, recipients) in [(overlap, overlapRecipients), (retired, retiredRecipients)] {
            _ = try await service.create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: state)],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "1", count: 64)
                ),
                store: store
            )
        }
        _ = try await service.verify(archiveURL: overlap, identityFileURL: oldIdentity)
        let verifiedByNew = try await service.verify(archiveURL: overlap, identityFileURL: newIdentity)
        XCTAssertEqual(verifiedByNew.sidecar.verificationHistory?.count, 2)
        do {
            _ = try await service.verify(archiveURL: retired, identityFileURL: oldIdentity)
            XCTFail("retired identity unexpectedly decrypted the new-only archive")
        } catch {
            XCTAssertFalse(String(describing: error).contains("AGE-SECRET-KEY"))
        }
        _ = try await service.verify(archiveURL: retired, identityFileURL: newIdentity)
        try await store.close(clean: false)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "pinned age integration command failed")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct InjectedRestoreFailure: Error {}
private struct InjectedRestorePublicationFailure: Error {}

private final class RestoreDurabilityEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
