import CryptoKit
import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRootTargetSeedPlanManifestTests: XCTestCase {
    private var roots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testManifestAuthenticatesSortedRecordsCountsAndEmptyDirectories() async throws {
        let root = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-root")
        let storeRoot = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-store")
        let store = try WorkspaceRootTargetSeedPlanManifestStore(
            directoryURL: storeRoot.appendingPathComponent("plans", isDirectory: true)
        )
        let writer = try store.makeWriter(
            header: header(root: root),
            resourcePolicy: policy(batch: 2, openRuns: 2)
        )
        try await writer.append(WorkspaceRootTargetSeedPlanRecord(
            relativePathBytes: Data("z.swift".utf8),
            disposition: .ordinaryFile,
            baseAction: .overlay,
            fileSystemMode: 0o100644
        ))
        try await writer.append(WorkspaceRootTargetSeedPlanRecord(
            relativePathBytes: Data("Empty/Leaf".utf8),
            disposition: .ordinaryDirectory,
            baseAction: .none,
            fileSystemMode: 0o040755
        ))
        try await writer.append(WorkspaceRootTargetSeedPlanRecord(
            relativePathBytes: Data("Empty".utf8),
            disposition: .ordinaryDirectory,
            baseAction: .none,
            fileSystemMode: 0o040755
        ))
        let lease = try await writer.finish()
        let reader = try lease.makeReader()
        var paths: [String] = []
        while let record = try reader.next() {
            paths.append(String(decoding: record.relativePathBytes, as: UTF8.self))
        }

        XCTAssertEqual(paths, ["Empty", "Empty/Leaf", "z.swift"])
        XCTAssertEqual(reader.validationState, .verified)
        XCTAssertEqual(lease.footer.recordCount, 3)
        XCTAssertEqual(lease.footer.ordinaryDirectoryCount, 2)
        XCTAssertEqual(lease.footer.overlayFileCount, 1)
        XCTAssertEqual(WorkspaceRootSeedCompatibilityKey.currentInventorySchemaVersion, 5)
        XCTAssertEqual(lease.header.schemaVersion, WorkspaceRootTargetSeedPlanManifestHeader.currentSchemaVersion)
    }

    func testManifestRejectsDuplicateByteExactPathWithoutPublishing() async throws {
        let root = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-duplicate-root")
        let storeRoot = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-duplicate-store")
        let store = try WorkspaceRootTargetSeedPlanManifestStore(
            directoryURL: storeRoot.appendingPathComponent("plans", isDirectory: true)
        )
        let writer = try store.makeWriter(
            header: header(root: root),
            resourcePolicy: policy(batch: 1, openRuns: 2)
        )
        let record = WorkspaceRootTargetSeedPlanRecord(
            relativePathBytes: Data("same".utf8),
            disposition: .ordinaryDirectory,
            baseAction: .none,
            fileSystemMode: 0o040755
        )
        try await writer.append(record)
        try await writer.append(record)
        do {
            _ = try await writer.finish()
            XCTFail("Expected duplicate path rejection")
        } catch let error as WorkspaceRootTargetSeedPlanManifestError {
            XCTAssertEqual(error, .duplicatePath)
        }
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    func testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn() async throws {
        let root = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-scale-root")
        let storeRoot = try roots.makeRoot(suiteName: "TargetSeedPlanManifest-scale-store")
        let store = try WorkspaceRootTargetSeedPlanManifestStore(
            directoryURL: storeRoot.appendingPathComponent("plans", isDirectory: true)
        )
        let writer = try store.makeWriter(
            header: header(root: root),
            resourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy(
                maximumBufferedRecordBytes: 1024 * 1024,
                maximumRecordsPerBatch: 2048,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 8,
                minimumFreeDiskBytes: 0
            )
        )
        let count = ProcessInfo.processInfo.environment["RPCE_RUN_MILLION_ENTRY_TESTS"] == "1"
            ? 1_000_000
            : 100_000
        var batch: [WorkspaceRootTargetSeedPlanRecord] = []
        batch.reserveCapacity(512)
        for value in 0 ..< count {
            batch.append(WorkspaceRootTargetSeedPlanRecord(
                relativePathBytes: Data(String(format: "files/%07d.swift", value).utf8),
                disposition: .ordinaryFile,
                baseAction: .overlay
            ))
            if batch.count == 512 {
                try await writer.append(contentsOf: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await writer.append(contentsOf: batch) }
        let lease = try await writer.finish()
        let reader = try lease.makeReader()
        var readCount = 0
        var previous: Data?
        while let record = try reader.next() {
            if let previous {
                XCTAssertTrue(previous.lexicographicallyPrecedes(record.relativePathBytes))
            }
            previous = record.relativePathBytes
            readCount += 1
        }
        XCTAssertEqual(readCount, count)
        XCTAssertEqual(reader.validationState, .verified)
        XCTAssertEqual(lease.footer.overlayFileCount, UInt64(count))
        XCTAssertLessThanOrEqual(lease.statistics.peakBufferedRecordBytes, 1024 * 1024)

        let seededInventory = try FileSystemSeededInventoryManifest(validating: lease)
        XCTAssertEqual(seededInventory.statistics.recordCount, UInt64(count))
        XCTAssertEqual(seededInventory.statistics.ordinaryFileCount, UInt64(count))
        XCTAssertEqual(seededInventory.statistics.ordinaryDirectoryCount, 0)
        XCTAssertLessThanOrEqual(
            seededInventory.statistics.peakResidentPathBytes,
            64 * 1024,
            "Seed preparation must retain only one decoded path plus at most 1,024 sparse checkpoints"
        )
        let seededReader = try seededInventory.makeReader()
        var seededCount = 0
        while try seededReader.next() != nil {
            seededCount += 1
        }
        XCTAssertEqual(seededCount, count)
    }

    private func header(root: URL) throws -> WorkspaceRootTargetSeedPlanManifestHeader {
        let digest = Data(SHA256.hash(data: Data("digest".utf8)))
        return try WorkspaceRootTargetSeedPlanManifestHeader(
            snapshotIdentityBytes: Data(String(repeating: "a", count: 64).utf8),
            targetTreeOIDBytes: Data(String(repeating: "b", count: 40).utf8),
            objectFormatBytes: Data("sha1".utf8),
            repositoryRelativeRootPrefixBytes: Data(),
            namespaceIdentity: WorkspaceRootNamespaceManifestIdentity(
                root: WorkspaceRootNamespaceRootIdentity(rootURL: root),
                catalogPolicy: .canonicalDefaults
            ),
            namespaceDigest: digest,
            treeDeltaDigest: digest,
            indexDigest: digest,
            statusDigest: digest,
            authorityIdentity: GitTargetEvidenceAuthorityIdentity(
                authorityGeneration: 1,
                invalidationGeneration: 0,
                acceptedMetadataWatermark: 0,
                attemptID: UUID(),
                snapshotDigestBytes: digest
            ),
            suppliedCreationCutProvenanceBytes: digest
        )
    }

    private func policy(batch: Int, openRuns: Int) -> WorkspaceRootTargetSeedPlanResourcePolicy {
        WorkspaceRootTargetSeedPlanResourcePolicy(
            maximumBufferedRecordBytes: 1024,
            maximumRecordsPerBatch: batch,
            maximumRecordByteCount: 512,
            maximumOpenRuns: openRuns,
            minimumFreeDiskBytes: 0
        )
    }
}
