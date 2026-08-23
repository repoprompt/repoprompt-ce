import Crypto
import Foundation
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

enum StoreMigrationTestSupport {
    static let knownV6Digests = [
        "repoprompt-service-schema-v6-typed-mcp-show-model-presets",
        "repoprompt-service-schema-v6-typed-mcp-disabled-tools",
        "repoprompt-service-schema-v6-typed-workspace-approvals",
        "repoprompt-service-schema-v6-typed-direct-agent-permissions",
        "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit",
        "repoprompt-service-schema-v6-agent-composer-semantic-acceptance",
        "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance",
    ]

    struct FrozenLegacyColumn: Codable, Sendable {
        let table: String
        let column: String
        let definition: String
    }

    struct FrozenSchemaVersionProgram: Codable, Sendable {
        let version: Int
        let ledgerDigest: String
        let transformationID: String
        let statements: [String]
        let operatorStatements: [String]?
        let legacyColumns: [FrozenLegacyColumn]?
        let dataStatements: [String]?
    }

    struct FrozenV6Program: Codable, Sendable {
        let programID: String
        let sourceCommit: String
        let sourceKind: String
        let ledgerDigest: String
        let transformationID: String
        let programDigest: String
        let statementsDigest: String
        let statements: [String]
    }

    private struct FrozenHistoricalPrograms: Codable, Sendable {
        let formatVersion: Int
        let baseSourceCommit: String
        let baseProgramDigest: String
        let baseStatementsDigest: String
        let versions1Through5: [FrozenSchemaVersionProgram]
        let v6Programs: [FrozenV6Program]
    }

    private static let frozenHistoricalPrograms: FrozenHistoricalPrograms = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Migrations/historical-schema-programs-v1.json")
        do {
            return try JSONDecoder().decode(FrozenHistoricalPrograms.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Frozen historical migration program fixture is invalid: \(error)")
        }
    }()

    static var frozenFormatVersion: Int {
        frozenHistoricalPrograms.formatVersion
    }

    static var frozenBaseSourceCommit: String {
        frozenHistoricalPrograms.baseSourceCommit
    }

    static var frozenVersions1Through5: [FrozenSchemaVersionProgram] {
        frozenHistoricalPrograms.versions1Through5
    }

    static var historicalV6Programs: [FrozenV6Program] {
        frozenHistoricalPrograms.v6Programs
    }

    static var frozenBaseProgramDigest: String {
        frozenHistoricalPrograms.baseProgramDigest
    }

    static var frozenBaseStatementsDigest: String {
        frozenHistoricalPrograms.baseStatementsDigest
    }

    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-pr4-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Constructs a V6 database only from checked-in V1–V6 programs. Historical
    /// labels select a frozen source program; the current label executes the
    /// current immutable V1–V6 definitions without ever creating or relabeling
    /// a V7 store.
    static func makeV6Store(at databaseURL: URL, digest: String = knownV6Digests[0]) async throws {
        if digest == knownV6Digests[0] {
            return try await makeStore(
                at: databaseURL,
                throughVersion: 6,
                ledgerDigestOverride: digest,
                historicalV6Program: nil
            )
        }
        let program = historicalV6Programs
            .filter { $0.ledgerDigest == digest }
            .sorted { $0.programID < $1.programID }
            .last
            ?? historicalV6Programs.first { $0.programID == "typed-settings" }
        try await makeStore(
            at: databaseURL,
            throughVersion: 6,
            ledgerDigestOverride: digest,
            historicalV6Program: program
        )
    }

    static func makeV6Store(at databaseURL: URL, programID: String) async throws {
        guard let program = historicalV6Programs.first(where: { $0.programID == programID }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try await makeStore(
            at: databaseURL,
            throughVersion: 6,
            ledgerDigestOverride: program.ledgerDigest,
            historicalV6Program: program
        )
    }

    static func makeHistoricalStore(at databaseURL: URL, throughVersion: Int) async throws {
        precondition((1 ... 6).contains(throughVersion))
        let program = throughVersion == 6
            ? historicalV6Programs.first(where: { $0.programID == "typed-settings" })
            : nil
        try await makeStore(
            at: databaseURL,
            throughVersion: throughVersion,
            ledgerDigestOverride: program?.ledgerDigest,
            historicalV6Program: program
        )
    }

    private static func makeStore(
        at databaseURL: URL,
        throughVersion: Int,
        ledgerDigestOverride: String?,
        historicalV6Program: FrozenV6Program?
    ) async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .file(path: databaseURL.path))
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        do {
            try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
                let historical = historicalV6Program != nil || throughVersion < 6
                let frozenVersions = frozenHistoricalPrograms.versions1Through5
                let v1Statements = historical ? frozenVersions[0].statements : SchemaV1.statements
                let operatorStatements = historical ? (frozenVersions[0].operatorStatements ?? []) : SchemaV1.operatorStatements
                for statement in v1Statements + operatorStatements {
                    _ = try await database.query(statement)
                }
                let legacyColumns: [FrozenLegacyColumn] = if historical {
                    frozenVersions[0].legacyColumns ?? []
                } else {
                    SchemaV1.legacyColumns.map {
                        FrozenLegacyColumn(table: $0.table, column: $0.column, definition: $0.definition)
                    }
                }
                for legacyColumn in legacyColumns {
                    let columns = Set(try await database.query("PRAGMA table_info(\(legacyColumn.table))")
                        .compactMap { $0.column("name")?.string })
                    if !columns.contains(legacyColumn.column) {
                        _ = try await database.query(
                            "ALTER TABLE \(legacyColumn.table) ADD COLUMN \(legacyColumn.column) \(legacyColumn.definition)"
                        )
                    }
                }
                _ = try await database.query(
                    "INSERT INTO service_metadata(fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor) VALUES(1,?,1,CURRENT_TIMESTAMP,0,1,1,0)",
                    [.text(UUID().uuidString)]
                )
                try await insertLedger(database, version: 1, digest: historical ? frozenVersions[0].ledgerDigest : SchemaV1.digest)

                guard throughVersion > 1 else { return }

                let currentPrograms: [(Int, [String], String)] = [
                    (2, SchemaV2.statements + SchemaV2.dataStatements, SchemaV2.digest),
                    (3, SchemaV3.statements, SchemaV3.digest),
                    (4, SchemaV4.statements, SchemaV4.digest),
                    (5, SchemaV5.statements, SchemaV5.digest),
                ]
                for version in 2 ... min(throughVersion, 5) {
                    let program: (version: Int, statements: [String], digest: String)
                    if historical {
                        let frozen = frozenVersions[version - 1]
                        program = (version, frozen.statements + (frozen.dataStatements ?? []), frozen.ledgerDigest)
                    } else {
                        program = currentPrograms[version - 2]
                    }
                    let (version, statements, digest) = program
                    for statement in statements { _ = try await database.query(statement) }
                    _ = try await database.query(
                        "UPDATE service_metadata SET schema_version=? WHERE fixed_id=1",
                        [.integer(version)]
                    )
                    try await insertLedger(database, version: version, digest: digest)
                }

                guard throughVersion == 6 else { return }
                for statement in historicalV6Program?.statements ?? SchemaV6.statements {
                    _ = try await database.query(statement)
                }
                _ = try await database.query("UPDATE service_metadata SET schema_version=6 WHERE fixed_id=1")
                try await insertLedger(
                    database,
                    version: 6,
                    digest: ledgerDigestOverride ?? SchemaV6.digest
                )
            }
            try await database.commitTransaction(transactionID)
        } catch {
            try? await database.rollbackTransaction(transactionID)
            try? await database.close()
            throw error
        }
        try await database.close()
    }

    private static func insertLedger(
        _ database: SQLiteDatabaseExecutor,
        version: Int,
        digest: String
    ) async throws {
        _ = try await database.query(
            "INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP)",
            [.text("v\(version)"), .integer(version), .text("historical fixture v\(version)"), .text(digest)]
        )
    }

    static func namespace(
        root: URL,
        mode: RepoPromptAuthorityServingMode = .server
    ) throws -> AuthorityNamespaceDescriptor {
        try AuthorityNamespaceDescriptor(
            storageRoot: root.path,
            databasePath: root.appendingPathComponent("repoprompt.sqlite").path,
            profile: "test",
            servingMode: mode
        )
    }

    static let defaultRecipient = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    static func identityFile(
        in root: URL,
        name: String = "identity.txt",
        recipient: String = defaultRecipient
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        // CopyingBackupEnvelope is deliberately not cryptography. The fixture
        // stores only a public recipient so unit tests can exercise custody
        // bookkeeping without inventing private-key evidence.
        try Data((recipient + "\n").utf8).write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        return url
    }

    static func recipientsFile(in root: URL, values: [String], name: String = "recipients.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((values.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    static func backupService(envelope: any BackupEnvelopeEncrypting = CopyingBackupEnvelope()) -> BackupRestoreService {
        BackupRestoreService(
            envelope: envelope,
            toolVersion: "RepoPromptServerTests/1",
            toolDigest: String(repeating: "a", count: 64)
        )
    }
}

struct CopyingBackupEnvelope: BackupEnvelopeEncrypting {
    func encrypt(plaintext: URL, recipientsFile _: URL, ciphertext: URL) async throws {
        try FileManager.default.copyItem(at: plaintext, to: ciphertext)
    }

    func decrypt(ciphertext: URL, identityFile _: URL, plaintext: URL) async throws {
        try FileManager.default.copyItem(at: ciphertext, to: plaintext)
    }

    func identityRecipientFingerprint(identityFile: URL) async throws -> String {
        let recipient = try String(contentsOf: identityFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(recipient.utf8)).map { String(format: "%02x", $0) }.joined()
        return "x25519:\(digest)"
    }
}

struct FailingBackupEnvelope: BackupEnvelopeEncrypting {
    enum Failure: Error { case injected }
    let failEncrypt: Bool

    func encrypt(plaintext: URL, recipientsFile _: URL, ciphertext: URL) async throws {
        if failEncrypt { throw Failure.injected }
        try FileManager.default.copyItem(at: plaintext, to: ciphertext)
    }

    func decrypt(ciphertext _: URL, identityFile _: URL, plaintext _: URL) async throws {
        throw Failure.injected
    }

    func identityRecipientFingerprint(identityFile _: URL) async throws -> String {
        throw Failure.injected
    }
}
