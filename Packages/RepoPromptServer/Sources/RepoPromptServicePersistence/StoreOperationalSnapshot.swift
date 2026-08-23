import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public struct CheckpointRetentionCount: Codable, Hashable, Sendable {
    public let retentionClass: String
    public let count: Int

    public init(retentionClass: String, count: Int) {
        self.retentionClass = retentionClass
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case retentionClass, count
    }
}

public struct StoreOperationalSnapshot: Codable, Sendable {
    public let integrityValid: Bool
    public let migrationsValid: Bool
    public let activationState: String
    public let activationGeneration: Int64
    public let liveEventCount: Int
    public let archiveSegmentCount: Int
    public let archivedEventCount: Int
    public let compressedArchiveBytes: Int64
    public let checkpointCounts: [CheckpointRetentionCount]
    public let activeProcessFamilyCount: Int
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let ownedResources: OwnedResourceHealthSnapshot
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case integrityValid, migrationsValid, activationState, activationGeneration
        case liveEventCount, archiveSegmentCount, archivedEventCount, compressedArchiveBytes
        case checkpointCounts, activeProcessFamilyCount, databaseBytes, walBytes
        case ownedResources, observedAt
    }
}

public extension SQLiteServiceStore {
    func operationalSnapshot(now: Date = Date()) async throws -> StoreOperationalSnapshot {
        let integrity = try await connection.query("PRAGMA quick_check").first?.columns.first?.data.string == "ok"
        let migrations = try await connection.query("SELECT version,digest FROM schema_migrations ORDER BY version")
        let migrationMap = Dictionary(uniqueKeysWithValues: migrations.compactMap { row -> (Int, String)? in
            guard let version = row.column("version")?.integer,
                  let digest = row.column("digest")?.string
            else { return nil }
            return (version, digest)
        })
        let metadata = try await metadata()
        let migrationsValid = metadata.schemaVersion == SchemaV6.version
            && migrationMap[1] == "v1"
            && migrationMap[SchemaV2.version] == SchemaV2.digest
            && migrationMap[SchemaV3.version] == SchemaV3.digest
            && migrationMap[SchemaV4.version] == SchemaV4.digest
            && migrationMap[SchemaV5.version] == SchemaV5.digest
            && migrationMap[SchemaV6.version] == SchemaV6.digest
        let liveEventCount = try await scalarInt("SELECT COUNT(*) AS value FROM events")
        let archiveSegmentCount = try await scalarInt("SELECT COUNT(*) AS value FROM event_archive_blobs")
        let archivedEventCount = try await scalarInt("SELECT COALESCE(SUM(event_count),0) AS value FROM event_archive_blobs")
        let compressedArchiveBytes = try await Int64(scalarInt("SELECT COALESCE(SUM((LENGTH(compressed_events_base64) * 3) / 4),0) AS value FROM event_archive_blobs"))
        let checkpointCounts = try await connection.query("SELECT retention_class,COUNT(*) AS count FROM snapshot_checkpoints GROUP BY retention_class ORDER BY retention_class").map {
            CheckpointRetentionCount(
                retentionClass: $0.column("retention_class")?.string ?? "unknown",
                count: $0.column("count")?.integer ?? 0
            )
        }
        let activeProcessFamilyCount = try await scalarInt("SELECT COUNT(*) AS value FROM process_families WHERE state IN ('running','terminating')")
        return try await StoreOperationalSnapshot(
            integrityValid: integrity,
            migrationsValid: migrationsValid,
            activationState: metadata.activationState,
            activationGeneration: metadata.activationGeneration,
            liveEventCount: liveEventCount,
            archiveSegmentCount: archiveSegmentCount,
            archivedEventCount: archivedEventCount,
            compressedArchiveBytes: compressedArchiveBytes,
            checkpointCounts: checkpointCounts,
            activeProcessFamilyCount: activeProcessFamilyCount,
            databaseBytes: fileBytes(storagePath),
            walBytes: fileBytes(storagePath.map { "\($0)-wal" }),
            ownedResources: ownedResourceHealth(now: now),
            observedAt: now
        )
    }

    func snapshotCheckpointDetails(scope: String) async throws -> [(sequence: Int64, digest: String, retentionClass: String)] {
        try await connection.query(
            "SELECT sequence,digest,retention_class FROM snapshot_checkpoints WHERE scope=? ORDER BY sequence",
            [.text(scope)]
        ).map {
            (
                Int64($0.column("sequence")?.integer ?? 0),
                $0.column("digest")?.string ?? "",
                $0.column("retention_class")?.string ?? "rolling"
            )
        }
    }

    private func scalarInt(_ sql: String) async throws -> Int {
        try await connection.query(sql).first?.column("value")?.integer ?? 0
    }

    private func fileBytes(_ path: String?) -> Int64 {
        guard let path,
              let number = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
        else { return 0 }
        return number.int64Value
    }
}
