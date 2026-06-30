import CryptoKit
import Darwin
@testable import RepoPrompt
import XCTest

final class GitTargetEvidenceManifestTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testTreeDeltaPreservesRawPathsAndSortsRenameRemovalBeforeUpsert() async throws {
        let (store, root) = try makeStore(suite: "tree")
        let identity = try identity(root: root, family: .treeDelta)
        let writer = try store.makeTreeDeltaWriter(
            identity: identity,
            resourcePolicy: policy(batchRecords: 1, openRuns: 2)
        )
        let rawPath = Data([0x64, 0x69, 0x72, 0x2F, 0x80, 0x09, 0x0A])
        let source = GitTargetTreeDeltaEvidenceRecord(
            oldModeBytes: Data("100644".utf8),
            newModeBytes: nil,
            oldObjectIDBytes: oid("a"),
            newObjectIDBytes: nil,
            status: .renamedSource,
            repositoryRelativePathBytes: rawPath
        )
        let destination = GitTargetTreeDeltaEvidenceRecord(
            oldModeBytes: Data("100644".utf8),
            newModeBytes: Data("100755".utf8),
            oldObjectIDBytes: oid("a"),
            newObjectIDBytes: oid("b"),
            status: .renamed,
            similarityScore: 92,
            sourceRepositoryRelativePathBytes: rawPath,
            repositoryRelativePathBytes: rawPath
        )
        try await writer.append(destination)
        try await writer.append(source)
        let lease = try await writer.finish()
        let (records, reader) = try readAll(lease)

        XCTAssertEqual(records, [source, destination])
        XCTAssertEqual(reader.validationState, .verified)
        XCTAssertEqual(reader.footer, lease.footer)
        XCTAssertEqual(lease.footer.recordCount, 2)
        XCTAssertEqual(lease.footer.pathPayloadByteCount, UInt64(rawPath.count * 3))
        XCTAssertGreaterThan(lease.statistics.initialRunCount, 1)
    }

    func testIndexCoalescesByteIdenticalDuplicatesAcrossRunsAndRejectsConflicts() async throws {
        let (store, root) = try makeStore(suite: "index-duplicates")
        let identity = try identity(root: root, family: .index)
        let record = GitTargetIndexEvidenceRecord(
            modeBytes: Data("100644".utf8),
            objectIDBytes: oid("c"),
            stage: 0,
            repositoryRelativePathBytes: Data(Array("path\twith\ncontrols".utf8) + [0xFF]),
            assumeUnchanged: true,
            skipWorktree: true
        )
        let writer = try store.makeIndexWriter(
            identity: identity,
            resourcePolicy: policy(batchRecords: 1, openRuns: 2)
        )
        try await writer.append(record)
        try await writer.append(record)
        let lease = try await writer.finish()
        let (records, reader) = try readAll(lease)
        XCTAssertEqual(records, [record])
        XCTAssertEqual(reader.validationState, .verified)
        XCTAssertEqual(lease.footer.recordCount, 1)

        let conflicting = GitTargetIndexEvidenceRecord(
            modeBytes: Data("100755".utf8),
            objectIDBytes: oid("d"),
            stage: 0,
            repositoryRelativePathBytes: record.repositoryRelativePathBytes,
            assumeUnchanged: true,
            skipWorktree: true
        )
        let conflictingWriter = try store.makeIndexWriter(
            identity: identity,
            resourcePolicy: policy(batchRecords: 1, openRuns: 2)
        )
        try await conflictingWriter.append(record)
        try await conflictingWriter.append(conflicting)
        do {
            _ = try await conflictingWriter.finish()
            XCTFail("Expected incompatible same-key index records to fail closed")
        } catch let error as GitTargetEvidenceManifestError {
            XCTAssertEqual(error, .duplicateRecord)
        }
    }

    func testStatusPreservesDirectoryMarkerOutsideRawPathSortKey() async throws {
        let (store, root) = try makeStore(suite: "status")
        let writer = try store.makeStatusWriter(
            identity: identity(root: root, family: .porcelainV2Status),
            resourcePolicy: policy(batchRecords: 1, openRuns: 2)
        )
        let directory = GitTargetStatusEvidenceRecord(
            kind: .untracked,
            repositoryRelativePathBytes: Data([
                0x75, 0x6E, 0x74, 0x72, 0x61, 0x63, 0x6B, 0x65, 0x64, 0x0A, 0xFF
            ]),
            isDirectoryMarker: true
        )
        let ignored = GitTargetStatusEvidenceRecord(
            kind: .ignored,
            repositoryRelativePathBytes: Data("ignored\tfile".utf8)
        )
        try await writer.append(directory)
        try await writer.append(ignored)
        let lease = try await writer.finish()
        let (records, reader) = try readAll(lease)

        XCTAssertEqual(Set(records.map(\.repositoryRelativePathBytes)), Set([
            directory.repositoryRelativePathBytes, ignored.repositoryRelativePathBytes
        ]))
        XCTAssertTrue(try XCTUnwrap(records.first(where: { $0.kind == .untracked })).isDirectoryMarker)
        XCTAssertFalse(records.contains(where: { $0.repositoryRelativePathBytes.last == UInt8(ascii: "/") }))
        XCTAssertEqual(reader.validationState, .verified)
    }

    func testReaderFailsTerminallyOnCorruptionAndTruncationAndBundleRejectsMismatchedAttempt() async throws {
        let (store, root) = try makeStore(suite: "corruption")
        let indexIdentity = try identity(root: root, family: .index)
        let corruptWriter = try store.makeIndexWriter(identity: indexIdentity)
        try await corruptWriter.append(indexRecord(path: "corrupt"))
        let corruptLease = try await corruptWriter.finish()
        let corruptReader = try corruptLease.makeReader()
        let corruptHandle = try FileHandle(forUpdating: corruptLease.fileURL)
        let corruptCount = try corruptHandle.seekToEnd()
        try corruptHandle.seek(toOffset: corruptCount / 2)
        let original = try XCTUnwrap(try corruptHandle.read(upToCount: 1)?.first)
        try corruptHandle.seek(toOffset: corruptCount / 2)
        try corruptHandle.write(contentsOf: Data([original ^ 0x01]))
        try corruptHandle.synchronize()
        try corruptHandle.close()
        XCTAssertThrowsError(try corruptReader.next())
        XCTAssertEqual(corruptReader.validationState, .failed)

        let writer = try store.makeIndexWriter(identity: indexIdentity)
        try await writer.append(indexRecord(path: "a"))
        let lease = try await writer.finish()
        let reader = try lease.makeReader()

        let handle = try FileHandle(forUpdating: lease.fileURL)
        let count = try handle.seekToEnd()
        try handle.truncate(atOffset: count - 1)
        try handle.synchronize()
        try handle.close()
        XCTAssertThrowsError(try reader.next())
        XCTAssertEqual(reader.validationState, .failed)
        XCTAssertNil(reader.footer)

        let treeWriter = try store.makeTreeDeltaWriter(
            identity: identity(root: root, family: .treeDelta)
        )
        let tree = try await treeWriter.finish()
        let statusWriter = try store.makeStatusWriter(
            identity: identity(root: root, family: .porcelainV2Status, attemptID: UUID())
        )
        let status = try await statusWriter.finish()
        XCTAssertThrowsError(try GitTargetEvidenceBundleLease(
            treeDelta: tree,
            index: lease,
            status: status
        )) { error in
            XCTAssertEqual(
                error as? GitTargetEvidenceManifestError,
                .corrupt("incoherent evidence bundle")
            )
        }
    }

    func testReaderRetainsArtifactAfterBundleAndLeaseRelease() async throws {
        let (store, root) = try makeStore(suite: "lifetime")
        let attempt = UUID()
        var tree: GitTargetTreeDeltaEvidenceLease? = try await store.makeTreeDeltaWriter(
            identity: identity(root: root, family: .treeDelta, attemptID: attempt)
        ).finish()
        var index: GitTargetIndexEvidenceLease? = try await store.makeIndexWriter(
            identity: identity(root: root, family: .index, attemptID: attempt)
        ).finish()
        var status: GitTargetStatusEvidenceLease? = try await store.makeStatusWriter(
            identity: identity(root: root, family: .porcelainV2Status, attemptID: attempt)
        ).finish()
        var bundle: GitTargetEvidenceBundleLease? = try GitTargetEvidenceBundleLease(
            treeDelta: XCTUnwrap(tree), index: XCTUnwrap(index), status: XCTUnwrap(status)
        )
        var reader: GitTargetIndexEvidenceReader? = try bundle?.makeIndexReader()
        let indexURL = try XCTUnwrap(index?.fileURL)

        bundle = nil
        tree = nil
        index = nil
        status = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertNil(try reader?.next())
        XCTAssertEqual(reader?.validationState, .verified)
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    func testCancelledWriterPublishesNothing() async throws {
        let (store, root) = try makeStore(suite: "cancellation")
        let writer = try store.makeIndexWriter(
            identity: identity(root: root, family: .index),
            resourcePolicy: policy(batchRecords: 2, openRuns: 2)
        )
        let task = Task {
            for index in 0 ..< 10000 {
                try await writer.append(indexRecord(path: String(format: "path-%05d", index)))
            }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testOptInMillionRecordMultiPassScaleHook() async throws {
        guard ProcessInfo.processInfo.environment["RPCE_RUN_GIT_EVIDENCE_1M"] == "1" else {
            throw XCTSkip("Set RPCE_RUN_GIT_EVIDENCE_1M=1 to run the one-million-record hook")
        }
        let (store, root) = try makeStore(suite: "million")
        let writer = try store.makeIndexWriter(
            identity: identity(root: root, family: .index),
            resourcePolicy: policy(batchRecords: 4096, openRuns: 8)
        )
        for base in stride(from: 0, to: 1_000_000, by: 256) {
            let records = (base ..< min(base + 256, 1_000_000)).reversed().map {
                indexRecord(path: String(format: "path-%07d", $0))
            }
            try await writer.append(contentsOf: records)
        }
        let lease = try await writer.finish()
        let reader = try lease.makeReader()
        var count = 0
        var previousPath: Data?
        while let record = try reader.next() {
            if let previousPath {
                XCTAssertTrue(previousPath.lexicographicallyPrecedes(record.repositoryRelativePathBytes))
            }
            previousPath = record.repositoryRelativePathBytes
            count += 1
        }
        XCTAssertEqual(count, 1_000_000)
        XCTAssertEqual(reader.validationState, .verified)
        XCTAssertGreaterThan(lease.statistics.mergePassCount, 1)
    }

    private func makeStore(suite: String) throws -> (GitTargetEvidenceManifestStore, URL) {
        let root = try temporaryRoots.makeRoot(suiteName: "GitTargetEvidence-\(suite)-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "GitTargetEvidence-\(suite)-store")
        return try (
            GitTargetEvidenceManifestStore(
                directoryURL: storeRoot.appendingPathComponent("evidence", isDirectory: true)
            ),
            root
        )
    }

    private func identity(
        root: URL,
        family: GitTargetEvidenceFamily,
        attemptID: UUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    ) throws -> GitTargetEvidenceArtifactIdentity {
        let fileSystemIdentity = try GitTargetEvidenceFileSystemIdentity(url: root)
        return GitTargetEvidenceArtifactIdentity(
            physicalWorktree: fileSystemIdentity,
            repositoryCommonDirectory: fileSystemIdentity,
            repositoryGitDirectory: fileSystemIdentity,
            authority: GitTargetEvidenceAuthorityIdentity(
                authorityGeneration: 7,
                invalidationGeneration: 11,
                acceptedMetadataWatermark: 13,
                attemptID: attemptID,
                snapshotDigestBytes: Data(SHA256.hash(data: Data("snapshot".utf8)))
            ),
            commandArguments: [Data("git".utf8), Data(familyArgument(family).utf8)],
            commandFormatBytes: Data(familyArgument(family).utf8),
            environmentIdentityBytes: Data(SHA256.hash(data: Data("environment".utf8))),
            commandOutputDigestBytes: Data(SHA256.hash(data: Data("output".utf8))),
            repositoryRelativeRootPrefixBytes: Data("root".utf8),
            objectFormatBytes: Data("sha1".utf8),
            baseObjectIDBytes: family == .treeDelta ? oid("1") : nil,
            targetObjectIDBytes: oid("2"),
            suppliedCreationCutProvenanceBytes: Data("cut".utf8),
            sparseCheckoutEnabled: family == .index ? false : nil
        )
    }

    private func familyArgument(_ family: GitTargetEvidenceFamily) -> String {
        switch family {
        case .treeDelta: "diff-tree-raw-z"
        case .index: "ls-files-stage-v-z"
        case .porcelainV2Status: "status-porcelain-v2-z"
        }
    }

    private func oid(_ character: Character) -> Data {
        Data(String(repeating: String(character), count: 40).utf8)
    }

    private func indexRecord(path: String) -> GitTargetIndexEvidenceRecord {
        GitTargetIndexEvidenceRecord(
            modeBytes: Data("100644".utf8),
            objectIDBytes: oid("f"),
            stage: 0,
            repositoryRelativePathBytes: Data(path.utf8),
            assumeUnchanged: false,
            skipWorktree: false
        )
    }

    private func policy(batchRecords: Int, openRuns: Int) -> GitTargetEvidenceResourcePolicy {
        GitTargetEvidenceResourcePolicy(
            maximumBufferedRecordBytes: 1024,
            maximumRecordsPerBatch: batchRecords,
            maximumRecordByteCount: 512,
            maximumOpenRuns: openRuns,
            minimumFreeDiskBytes: 0
        )
    }

    private func readAll<Codec: GitTargetEvidenceRecordCodec>(
        _ lease: GitTargetEvidenceManifestLease<Codec>
    ) throws -> ([Codec.Record], GitTargetEvidenceManifestReader<Codec>) {
        let reader = try lease.makeReader()
        var records: [Codec.Record] = []
        while let record = try reader.next() {
            records.append(record)
        }
        return (records, reader)
    }
}
