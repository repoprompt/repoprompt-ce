import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO
import XCTest
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

final class SchemaMigrationTests: XCTestCase {
    func testForwardVersionFailsWithoutMutation() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        _ = try await store.database.query("UPDATE service_metadata SET schema_version=8 WHERE fixed_id=1")
        try await store.close(clean: false)
        let before = try Data(contentsOf: databaseURL)
        do {
            _ = try await SQLiteServiceStore.openForServing(storage: .file(databaseURL.path))
            XCTFail("Expected forward schema refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .forwardSchemaUnsupported)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    func testUnknownV6DigestFailsBeforeMigration() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL, digest: "unknown-v6")

        let inspection = try await SQLiteDatabaseExecutor.open(storage: .file(path: databaseURL.path))
        let ledgerBefore = try await ledgerEvidence(inspection)
        try await inspection.close()
        let inventoryBefore = try sqliteInventory(databaseURL)

        do {
            _ = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
            XCTFail("Expected digest refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertTrue(error.message.contains("digest"))
        }

        XCTAssertEqual(
            try sqliteInventory(databaseURL),
            inventoryBefore,
            "digest refusal must precede SQLite WAL/configuration mutation"
        )
        let verification = try await SQLiteDatabaseExecutor.open(storage: .file(path: databaseURL.path))
        let ledgerAfter = try await ledgerEvidence(verification)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        try await verification.close()
    }

    func testStampedNamespaceKindMismatchIsRefused() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try StoreMigrationTestSupport.namespace(root: root)
        let store = try await SQLiteServiceStore.openForServing(
            storage: .file(namespace.databasePath),
            namespaceKind: "server",
            databaseIdentityDigest: namespace.namespaceID
        )
        try await store.close()
        do {
            _ = try await SQLiteServiceStore.openForServing(
                storage: .file(namespace.databasePath),
                namespaceKind: "directHeadless",
                databaseIdentityDigest: namespace.namespaceID
            )
            XCTFail("Expected namespace kind refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }
    }

    func testDatabaseIdentityDigestIsValidatedBeforeV7TransactionAdmission() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let source = try await store.migrationSourceEvidence()
        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "D", count: 1_048_576)
            )
            XCTFail("database identity must be a canonical lowercase SHA-256 digest")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        let metrics = await store.database.metrics()
        XCTAssertEqual(metrics.queuedByClass.values.reduce(0, +), 0)
        XCTAssertEqual(metrics.waitingByClass.values.reduce(0, +), 0)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        try await store.close(clean: false)
    }

    func testBusyMigrationIsRetryableAndPreservesV6() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let source = try await store.migrationSourceEvidence()
        let blocker = try await SQLiteConnection.open(storage: .file(path: databaseURL.path))
        _ = try await blocker.query("PRAGMA busy_timeout=100")
        _ = try await blocker.query("BEGIN IMMEDIATE")
        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            XCTFail("Expected busy migration failure")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertTrue(error.retryable)
        }
        _ = try await blocker.query("ROLLBACK")
        try await blocker.close()
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        let v7Tables = try await store.database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_compatibility_audit','authority_namespace_identity')"
        )
        XCTAssertTrue(v7Tables.isEmpty)
        try await store.close(clean: false)
    }

    func testRestoreRequestCannotBypassIdentityWithoutExplicitActivationStartup() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let source = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        try await source.close(clean: false)
        try Data("{}".utf8).write(to: root.appendingPathComponent("restore-request.json"))

        do {
            _ = try await SQLiteServiceStore.openForServing(
                storage: .file(databaseURL.path),
                namespaceKind: "server",
                databaseIdentityDigest: targetDigest
            )
            XCTFail("Ordinary startup accepted a pending restore identity rebind")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }

        let activationOpen = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: targetDigest,
            allowPendingRestoreRebind: true
        )
        try await activationOpen.close(clean: false)
    }

    private func ledgerEvidence(_ database: SQLiteDatabaseExecutor) async throws -> [String] {
        try await database.query("SELECT version,digest FROM schema_migrations ORDER BY version").map {
            "\($0.column("version")?.integer ?? -1):\($0.column("digest")?.string ?? "")"
        }
    }

    private func sqliteInventory(_ databaseURL: URL) throws -> [String: Data] {
        var inventory: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                inventory[suffix.isEmpty ? "database" : suffix] = try Data(contentsOf: url)
            }
        }
        return inventory
    }
}

final class SQLiteTransactionFaultInjectionTests: XCTestCase {
    func testEveryV7StatementInterruptionAndCancellationBoundaryPreservesBytesAndLedger() async throws {
        let statementCount = try await countHistoricalV7StatementBoundaries()
        XCTAssertGreaterThan(statementCount, SchemaV6.statements.count)
        let boundaries = [(PersistenceFaultPoint.afterTransactionBegin, 1)]
            + (1 ... statementCount).map { (PersistenceFaultPoint.afterMigrationStatement, $0) }
            + [
                (PersistenceFaultPoint.beforeMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.afterMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.beforeTransactionCommit, 1),
            ]

        for (point, occurrence) in boundaries {
            try await assertFailedMigrationPreservesV6(
                point: point,
                occurrence: occurrence
            )
        }
    }

    func testActualTaskCancellationAtEveryV7BoundaryPreservesBytesAndLedger() async throws {
        let statementCount = try await countHistoricalV7StatementBoundaries()
        let boundaries = [(PersistenceFaultPoint.afterTransactionBegin, 1)]
            + (1 ... statementCount).map { (PersistenceFaultPoint.afterMigrationStatement, $0) }
            + [
                (PersistenceFaultPoint.beforeMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.afterMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.beforeTransactionCommit, 1),
            ]
        for (point, occurrence) in boundaries {
            try await assertCancelledMigrationPreservesV6(point: point, occurrence: occurrence)
        }
    }

    private func countHistoricalV7StatementBoundaries() async throws -> Int {
        let root = try StoreMigrationTestSupport.temporaryDirectory("count-v7-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(
            at: databaseURL,
            digest: StoreMigrationTestSupport.knownV6Digests[4]
        )
        let counter = MigrationFaultCounter(target: nil, occurrence: 0, cancellation: false)
        let store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(databaseURL.path),
            faultInjector: PersistenceFaultInjector { point in try counter.hit(point) }
        )
        let source = try await store.migrationSourceEvidence()
        _ = try await store.migrateToLatest(
            verifiedBackup: verifiedBackup(source),
            namespaceKind: "server",
            databaseIdentityDigest: String(repeating: "d", count: 64)
        )
        let count = counter.count(for: .afterMigrationStatement)
        try await store.close(clean: false)
        return count
    }

    private func assertFailedMigrationPreservesV6(
        point: PersistenceFaultPoint,
        occurrence: Int
    ) async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("\(point.rawValue)-\(occurrence)-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(
            at: databaseURL,
            digest: StoreMigrationTestSupport.knownV6Digests[4]
        )
        let counter = MigrationFaultCounter(target: point, occurrence: occurrence, cancellation: false)
        var store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(databaseURL.path),
            faultInjector: PersistenceFaultInjector { hit in try counter.hit(hit) }
        )
        let source = try await store.migrationSourceEvidence()
        let database = await store.database
        let ledgerBefore = try await ledgerEvidence(database)
        let bytesBefore = try Data(contentsOf: databaseURL)

        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: verifiedBackup(source),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            XCTFail("expected fault at \(point.rawValue)#\(occurrence)")
        } catch is InjectedMigrationFailure {
            // Expected injected statement boundary failure.
        }

        let bytesAfter = try Data(contentsOf: databaseURL)
        let ledgerAfter = try await ledgerEvidence(database)
        let metadataAfter = try await store.metadata()
        let v7Ledger = try await database.query("SELECT version FROM schema_migrations WHERE version=7").first
        let v7Tables = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_compatibility_audit','authority_namespace_identity')"
        )
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(metadataAfter.schemaVersion, 6)
        XCTAssertNil(v7Ledger)
        XCTAssertTrue(v7Tables.isEmpty)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let reopenedMetadata = try await store.metadata()
        let reopenedDatabase = await store.database
        let reopenedLedger = try await ledgerEvidence(reopenedDatabase)
        XCTAssertEqual(reopenedMetadata.schemaVersion, 6)
        XCTAssertEqual(reopenedLedger, ledgerBefore)
        try await store.close(clean: false)
    }

    private func assertCancelledMigrationPreservesV6(
        point: PersistenceFaultPoint,
        occurrence: Int
    ) async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("\(point.rawValue)-\(occurrence)-task-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(
            at: databaseURL,
            programID: "typed-settings"
        )
        let gate = MigrationCancellationGate(target: point, occurrence: occurrence)
        let store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(databaseURL.path),
            faultInjector: PersistenceFaultInjector { hit in try await gate.hit(hit) }
        )
        let source = try await store.migrationSourceEvidence()
        let database = await store.database
        let ledgerBefore = try await ledgerEvidence(database)
        let bytesBefore = try Data(contentsOf: databaseURL)
        let backup = verifiedBackup(source)

        let migration = Task {
            try await store.migrateToLatest(
                verifiedBackup: backup,
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
        }
        await gate.waitUntilReached()
        migration.cancel()
        do {
            _ = try await migration.value
            XCTFail("migration should observe real task cancellation at \(point.rawValue)#\(occurrence)")
        } catch is CancellationError {}

        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
        let ledgerAfter = try await ledgerEvidence(database)
        let metadataAfter = try await store.metadata()
        let v7Ledger = try await database.query("SELECT version FROM schema_migrations WHERE version=7").first
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(metadataAfter.schemaVersion, 6)
        XCTAssertNil(v7Ledger)
        try await store.close(clean: false)

        let reopened = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let reopenedMetadata = try await reopened.metadata()
        let reopenedDatabase = await reopened.database
        let reopenedLedger = try await ledgerEvidence(reopenedDatabase)
        XCTAssertEqual(reopenedMetadata.schemaVersion, 6)
        XCTAssertEqual(reopenedLedger, ledgerBefore)
        try await reopened.close(clean: false)
    }

    private func ledgerEvidence(_ database: SQLiteDatabaseExecutor) async throws -> [String] {
        try await database.query("SELECT version,digest FROM schema_migrations ORDER BY version").map {
            "\($0.column("version")?.integer ?? -1):\($0.column("digest")?.string ?? "")"
        }
    }

    private func sqliteInventory(_ databaseURL: URL) throws -> [String: Data] {
        var inventory: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                inventory[suffix.isEmpty ? "database" : suffix] = try Data(contentsOf: url)
            }
        }
        return inventory
    }

    private func verifiedBackup(_ source: MigrationSourceEvidence) -> VerifiedMigrationBackup {
        VerifiedMigrationBackup(
            source: source,
            archiveSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            verifierFingerprint: String(repeating: "c", count: 64)
        )
    }

    func testCanonicalMigrationDigestsMatchCheckedInPrograms() {
        let migrations: [(version: Int, frozen: String, computed: String)] = [
            (SchemaV1.version, SchemaV1.canonicalDigest, SchemaV1.definition.computedDigest),
            (SchemaV2.version, SchemaV2.canonicalDigest, SchemaV2.definition.computedDigest),
            (SchemaV3.version, SchemaV3.canonicalDigest, SchemaV3.definition.computedDigest),
            (SchemaV4.version, SchemaV4.canonicalDigest, SchemaV4.definition.computedDigest),
            (SchemaV5.version, SchemaV5.canonicalDigest, SchemaV5.definition.computedDigest),
            (SchemaV6.version, SchemaV6.canonicalDigest, SchemaV6.definition.computedDigest),
            (SchemaV7.version, SchemaV7.canonicalDigest, SchemaV7.definition.computedDigest),
        ]
        XCTAssertEqual(migrations.map(\.version), Array(1 ... 7))
        for migration in migrations {
            XCTAssertEqual(
                migration.computed,
                migration.frozen,
                "migration V\(migration.version) is immutable; append a new version instead of changing its program"
            )
        }
    }
}

#if canImport(Darwin) || canImport(Glibc)
    final class SchemaMigrationCrashSubprocessTests: XCTestCase {
        private enum Environment {
            static let database = "REPOPROMPT_MIGRATION_CRASH_DATABASE"
            static let point = "REPOPROMPT_MIGRATION_CRASH_POINT"
            static let occurrence = "REPOPROMPT_MIGRATION_CRASH_OCCURRENCE"
            static let ready = "REPOPROMPT_MIGRATION_CRASH_READY"
        }

        func testSIGKILLAtEveryProductionMigrationBoundaryPreservesBytesAndLedger() async throws {
            guard ProcessInfo.processInfo.environment[Environment.database] == nil else {
                throw XCTSkip("parent-only migration crash test")
            }
            let statementCount = try await countStatementBoundaries()
            let boundaries = [(PersistenceFaultPoint.afterTransactionBegin, 1)]
                + (1 ... statementCount).map { (PersistenceFaultPoint.afterMigrationStatement, $0) }
                + [
                    (PersistenceFaultPoint.beforeMigrationLedgerInsert, 1),
                    (PersistenceFaultPoint.afterMigrationLedgerInsert, 1),
                    (PersistenceFaultPoint.beforeTransactionCommit, 1),
                ]

            for (point, occurrence) in boundaries {
                FileHandle.standardError.write(
                    Data("SIGKILL migration boundary \(point.rawValue)#\(occurrence)\n".utf8)
                )
                let root = try StoreMigrationTestSupport.temporaryDirectory(
                    "sigkill-\(point.rawValue)-\(occurrence)"
                )
                defer { try? FileManager.default.removeItem(at: root) }
                let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
                let readyURL = root.appendingPathComponent("child-ready")
                try await StoreMigrationTestSupport.makeV6Store(
                    at: databaseURL,
                    programID: "typed-settings"
                )
                let prepared = try await SQLiteServiceStore.openForMaintenance(
                    storage: .file(databaseURL.path)
                )
                try await prepared.close(clean: false)
                let bytesBefore = try Data(contentsOf: databaseURL)
                let ledgerBefore = try await ledger(at: databaseURL)

                let process = Process()
                guard let xctestPath = ProcessInfo.processInfo.arguments.first else {
                    return XCTFail("current xctest executable path is unavailable")
                }
                process.executableURL = URL(fileURLWithPath: xctestPath)
                #if canImport(Darwin)
                    process.arguments = [
                        "-XCTest",
                        "RepoPromptServerTests.SchemaMigrationCrashSubprocessTests/testCrashWorker",
                        Bundle(for: SchemaMigrationCrashSubprocessTests.self).bundleURL.path,
                    ]
                #else
                    process.arguments = [
                        "RepoPromptServerTests.SchemaMigrationCrashSubprocessTests/testCrashWorker",
                    ]
                #endif
                var environment = ProcessInfo.processInfo.environment
                environment[Environment.database] = databaseURL.path
                environment[Environment.point] = point.rawValue
                environment[Environment.occurrence] = String(occurrence)
                environment[Environment.ready] = readyURL.path
                process.environment = environment
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                try process.run()

                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !FileManager.default.fileExists(atPath: readyURL.path),
                      process.isRunning,
                      ContinuousClock.now < deadline
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard FileManager.default.fileExists(atPath: readyURL.path) else {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    let didExit = await waitForExit(process, timeout: .seconds(2))
                    let diagnostics = didExit
                        ? String(
                            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self
                        )
                        : "child ignored SIGKILL terminal-state polling"
                    return XCTFail(
                        "migration child failed to reach \(point.rawValue)#\(occurrence): \(diagnostics)"
                    )
                }
                XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
                guard await waitForExit(process, timeout: .seconds(2)) else {
                    _ = kill(process.processIdentifier, SIGKILL)
                    return XCTFail("killed migration child did not reach a terminal state")
                }
                _ = output.fileHandleForReading.readDataToEndOfFile()
                _ = errors.fileHandleForReading.readDataToEndOfFile()
                XCTAssertEqual(process.terminationReason, .uncaughtSignal)
                XCTAssertEqual(process.terminationStatus, SIGKILL)

                let reopened = try await SQLiteServiceStore.openForMaintenance(
                    storage: .file(databaseURL.path)
                )
                let reopenedMetadata = try await reopened.metadata()
                let reopenedDatabase = await reopened.database
                let reopenedLedger = try await ledger(database: reopenedDatabase)
                let v7Ledger = try await reopenedDatabase.query(
                    "SELECT version FROM schema_migrations WHERE version=7"
                ).first
                XCTAssertEqual(reopenedMetadata.schemaVersion, 6)
                XCTAssertEqual(reopenedLedger, ledgerBefore)
                XCTAssertNil(v7Ledger)
                try await reopened.close(clean: false)
                XCTAssertEqual(
                    try Data(contentsOf: databaseURL),
                    bytesBefore,
                    "hot-journal recovery must restore the exact pre-migration main-database bytes"
                )
            }
        }

        private func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return !process.isRunning
        }

        func testCrashWorker() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let databasePath = environment[Environment.database],
                  let pointValue = environment[Environment.point],
                  let point = PersistenceFaultPoint(rawValue: pointValue),
                  let occurrenceValue = environment[Environment.occurrence],
                  let occurrence = Int(occurrenceValue),
                  let readyPath = environment[Environment.ready]
            else {
                throw XCTSkip("migration crash subprocess only")
            }
            let pause = MigrationProcessPause(
                target: point,
                occurrence: occurrence,
                readyURL: URL(fileURLWithPath: readyPath)
            )
            let store = try await SQLiteServiceStore.openForMaintenance(
                storage: .file(databasePath),
                faultInjector: PersistenceFaultInjector { hit in try await pause.hit(hit) }
            )
            let source = try await store.migrationSourceEvidence()
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            XCTFail("crash worker unexpectedly completed")
        }

        private func countStatementBoundaries() async throws -> Int {
            let root = try StoreMigrationTestSupport.temporaryDirectory("count-process-boundaries")
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
            try await StoreMigrationTestSupport.makeV6Store(
                at: databaseURL,
                programID: "typed-settings"
            )
            let counter = MigrationFaultCounter(target: nil, occurrence: 0, cancellation: false)
            let store = try await SQLiteServiceStore.openForMaintenance(
                storage: .file(databaseURL.path),
                faultInjector: PersistenceFaultInjector { point in try counter.hit(point) }
            )
            let source = try await store.migrationSourceEvidence()
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            try await store.close(clean: false)
            return counter.count(for: .afterMigrationStatement)
        }

        private func ledger(at url: URL) async throws -> [String] {
            let database = try await SQLiteDatabaseExecutor.open(storage: .file(path: url.path))
            let value = try await ledger(database: database)
            try await database.close()
            return value
        }

        private func ledger(database: SQLiteDatabaseExecutor) async throws -> [String] {
            try await database.query("SELECT version,digest FROM schema_migrations ORDER BY version").map {
                "\($0.column("version")?.integer ?? -1):\($0.column("digest")?.string ?? "")"
            }
        }
    }

    private actor MigrationProcessPause {
        private let target: PersistenceFaultPoint
        private let occurrence: Int
        private let readyURL: URL
        private var counts: [String: Int] = [:]

        init(target: PersistenceFaultPoint, occurrence: Int, readyURL: URL) {
            self.target = target
            self.occurrence = occurrence
            self.readyURL = readyURL
        }

        func hit(_ point: PersistenceFaultPoint) async throws {
            let count = counts[point.rawValue, default: 0] + 1
            counts[point.rawValue] = count
            guard point == target, count == occurrence else { return }
            try Data("ready\n".utf8).write(to: readyURL, options: .atomic)
            while true { try await Task.sleep(for: .seconds(60)) }
        }
    }
#endif

private struct InjectedMigrationFailure: Error {}

private actor MigrationCancellationGate {
    private let target: PersistenceFaultPoint
    private let occurrence: Int
    private var counts: [String: Int] = [:]
    private var reached = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []

    init(target: PersistenceFaultPoint, occurrence: Int) {
        self.target = target
        self.occurrence = occurrence
    }

    func hit(_ point: PersistenceFaultPoint) async throws {
        let count = counts[point.rawValue, default: 0] + 1
        counts[point.rawValue] = count
        guard point == target, count == occurrence else { return }
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }
}

private final class MigrationFaultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let target: PersistenceFaultPoint?
    private let occurrence: Int
    private let cancellation: Bool
    private var counts: [String: Int] = [:]

    init(target: PersistenceFaultPoint?, occurrence: Int, cancellation: Bool) {
        self.target = target
        self.occurrence = occurrence
        self.cancellation = cancellation
    }

    func hit(_ point: PersistenceFaultPoint) throws {
        lock.lock()
        let count = counts[point.rawValue, default: 0] + 1
        counts[point.rawValue] = count
        let shouldFail = point == target && count == occurrence
        lock.unlock()
        if shouldFail {
            if cancellation { throw CancellationError() }
            throw InjectedMigrationFailure()
        }
    }

    func count(for point: PersistenceFaultPoint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[point.rawValue, default: 0]
    }
}
