import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO
@testable import RepoPromptServicePersistence
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ServingMigrationRefusalTests: XCTestCase {
    func testNonSQLiteBytesAreRejectedBeforeSQLiteMutation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let original = Data("foreign-authority-state".utf8)
        try original.write(to: URL(fileURLWithPath: path))

        do {
            _ = try await SQLiteServiceStore.openForServing(storage: .file(path))
            XCTFail("non-SQLite authority state unexpectedly opened")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorityPurposeMismatch)
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
    }

    func testForeignAndPartialSQLiteFilesAreRejectedWithoutDDL() async throws {
        for ddl in [
            "CREATE TABLE unrelated(value TEXT)",
            "CREATE TABLE service_metadata(fixed_id INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL)"
        ] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("state.sqlite").path
            let connection = try await SQLiteConnection.open(storage: .file(path: path))
            _ = try await connection.query(ddl)
            let schemaBefore = try await connection.query(
                "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
            ).map(Self.schemaRow)
            try await connection.close()

            do {
                _ = try await SQLiteServiceStore.openForServing(storage: .file(path))
                XCTFail("foreign or partial SQLite authority state unexpectedly opened")
            } catch let error as ServiceAPIError {
                XCTAssertEqual(error.code, .authorityPurposeMismatch)
            }

            let inspection = try await SQLiteConnection.open(storage: .file(path: path))
            let schemaAfter = try await inspection.query(
                "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
            ).map(Self.schemaRow)
            try await inspection.close()
            XCTAssertEqual(schemaAfter, schemaBefore)
        }
    }

    func testEveryPendingVersionIsRefusedWithoutLedgerOrSchemaMutation() async throws {
        for pendingVersion in 1 ... 6 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("state.sqlite").path
            try await StoreMigrationTestSupport.makeHistoricalStore(
                at: URL(fileURLWithPath: path),
                throughVersion: pendingVersion
            )
            let initialized = try await SQLiteDatabaseExecutor.open(storage: .file(path: path))
            let ledgerBefore = try await initialized.query(
                "SELECT version,digest FROM schema_migrations ORDER BY version"
            ).map(Self.ledgerRow)
            try await initialized.close()
            let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: path))

            do {
                _ = try await SQLiteServiceStore.openForServing(storage: .file(path))
                XCTFail("serving unexpectedly migrated schema v\(pendingVersion)")
            } catch let error as ServiceAPIError {
                XCTAssertEqual(error.code, .migrationRequired)
            }

            let connection = try await SQLiteConnection.open(storage: .file(path: path))
            let version = try await connection.query(
                "SELECT schema_version FROM service_metadata WHERE fixed_id=1"
            ).first?.column("schema_version")?.integer
            let ledgerAfter = try await connection.query(
                "SELECT version,digest FROM schema_migrations ORDER BY version"
            ).map(Self.ledgerRow)
            try await connection.close()
            XCTAssertEqual(version, pendingVersion)
            XCTAssertEqual(ledgerAfter, ledgerBefore)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytesBefore)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func schemaRow(_ row: SQLiteRow) -> String {
        [row.column("type")?.string, row.column("name")?.string, row.column("sql")?.string]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    private static func ledgerRow(_ row: SQLiteRow) -> String {
        "\(row.column("version")?.integer ?? -1):\(row.column("digest")?.string ?? "")"
    }
}
