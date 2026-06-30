import CryptoKit
import Darwin
@testable import RepoPrompt
import XCTest

final class WorkspaceRootNamespaceManifestTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testOrdinaryEnumerationParityIncludesEmptyAndNestedTopologyWithDeterministicDigest() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-store")
        try FileSystemTestSupport.write("hidden", to: root.appendingPathComponent(".hidden"))
        try FileSystemTestSupport.write("visible", to: root.appendingPathComponent("Visible/file.txt"))
        try FileSystemTestSupport.write("nested", to: root.appendingPathComponent("NestedRepo/source.swift"))
        try FileSystemTestSupport.write("git", to: root.appendingPathComponent("NestedRepo/.git/config"))
        try FileSystemTestSupport.write("ignored", to: root.appendingPathComponent("Ignored/file.txt"))
        try FileSystemTestSupport.write("Ignored/\n", to: root.appendingPathComponent(".repo_ignore"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Empty/Deep/Leaf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let executable = root.appendingPathComponent("script.sh")
        try FileSystemTestSupport.write("#!/bin/sh\n", to: executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        try FileSystemTestSupport.createDirectorySymlinkOrSkip(
            at: root.appendingPathComponent("VisibleLink"),
            destination: root.appendingPathComponent("Visible", isDirectory: true)
        )

        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: true,
            respectCursorignore: false,
            skipSymlinks: true
        )
        let ordinaryPaths = try await FileSystemTestSupport.collectRelativePaths(from: service, root: root)
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let first = try await service.workspaceRootNamespaceManifest(
            in: store,
            resourcePolicy: policy(bufferBytes: 128, batchRecords: 3, openRuns: 2),
            chunkSize: 2
        )
        let second = try await service.workspaceRootNamespaceManifest(
            in: store,
            resourcePolicy: policy(bufferBytes: 256, batchRecords: 5, openRuns: 3),
            chunkSize: 3
        )
        let records = try readAll(first)
        let manifestPaths = Set(records.map { String(decoding: $0.relativePathBytes, as: UTF8.self) })

        XCTAssertEqual(manifestPaths, ordinaryPaths)
        XCTAssertTrue(manifestPaths.isSuperset(of: ["Empty", "Empty/Deep", "Empty/Deep/Leaf"]))
        XCTAssertTrue(manifestPaths.isSuperset(of: ["NestedRepo", "NestedRepo/source.swift", ".hidden"]))
        XCTAssertFalse(manifestPaths.contains("Ignored"))
        XCTAssertFalse(manifestPaths.contains("NestedRepo/.git"))
        XCTAssertFalse(manifestPaths.contains("VisibleLink"))
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(first.footer.directoryCount, UInt64(records.count(where: { $0.kind == .directory })))
        XCTAssertEqual(first.footer.fileCount, UInt64(records.count(where: { $0.kind == .file })))
        XCTAssertEqual(records.map(\.relativePathBytes), records.map(\.relativePathBytes).sorted(by: { $0.lexicographicallyPrecedes($1) }))
        XCTAssertTrue(records.first(where: {
            String(decoding: $0.relativePathBytes, as: UTF8.self) == "script.sh"
        })?.isExecutable == true)
    }

    func testEnumerationFailsClosedWhenCatalogPolicyGenerationChanges() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-policy-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-policy-store")
        try FileSystemTestSupport.write("value", to: root.appendingPathComponent("file.txt"))
        let service = try await FileSystemService(path: root.path, skipSymlinks: true)
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        await service.setWorkspaceRootNamespaceEnumerationWillFinishHandlerForTesting {
            await service.updateSkipSymlinks(false)
        }

        do {
            _ = try await service.workspaceRootNamespaceManifest(
                in: store,
                resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
            )
            XCTFail("Expected the policy-generation fence to reject the manifest")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .corrupt("workspace ignore policy changed or rebuild pending during enumeration"))
        }
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testEnumerationFailsClosedWhileIgnoreRulesRebuildIsPending() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-rebuild-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-rebuild-store")
        try FileSystemTestSupport.write("value", to: root.appendingPathComponent("file.txt"))
        let service = try await FileSystemService(path: root.path)
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        await service.setWorkspaceRootNamespaceEnumerationWillFinishHandlerForTesting {
            await service.setPendingIgnoreRulesRebuildCountForTesting(1)
        }

        do {
            _ = try await service.workspaceRootNamespaceManifest(
                in: store,
                resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
            )
            XCTFail("Expected pending ignore rebuild state to reject the manifest")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .corrupt("workspace ignore policy changed or rebuild pending during enumeration"))
        }
        await service.setWorkspaceRootNamespaceEnumerationWillFinishHandlerForTesting(nil)
        do {
            _ = try await service.workspaceRootNamespaceManifest(in: store)
            XCTFail("Expected acquisition to reject an already-pending ignore rebuild")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .corrupt("workspace ignore rules rebuild pending during enumeration"))
        }
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testEnumerationPreservesRawNameBytesAndDanglingSymlinkFileSemantics() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-bytes-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-bytes-store")
        let rawNameBytes: [UInt8] = [0x72, 0x61, 0x77, 0x2D, 0x80]
        let createdRawFile = try createRawFile(named: rawNameBytes, in: root)
        defer {
            if createdRawFile { removeRawFile(named: rawNameBytes, from: root) }
        }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dangling-link").path,
            withDestinationPath: "missing-target"
        )
        let service = try await FileSystemService(path: root.path, skipSymlinks: false)
        let ordinaryPaths = try await FileSystemTestSupport.collectRelativePaths(from: service, root: root)
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let lease = try await service.workspaceRootNamespaceManifest(
            in: store,
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let records = try readAll(lease)

        if createdRawFile {
            XCTAssertTrue(ordinaryPaths.contains(String(decoding: rawNameBytes, as: UTF8.self)))
            XCTAssertEqual(records.first(where: { $0.relativePathBytes == Data(rawNameBytes) })?.kind, .file)
        } else {
            let decoded = String(decoding: rawNameBytes, as: UTF8.self)
            let record = FileSystemService.workspaceRootNamespaceRecord(for: FSItemDTO(
                relativePath: decoded,
                relativePathBytes: Data(rawNameBytes),
                isDirectory: false,
                hierarchy: 0,
                fileSystemMode: UInt16(S_IFREG | 0o600)
            ))
            XCTAssertEqual(record.relativePathBytes, Data(rawNameBytes))
            XCTAssertEqual(String(decoding: record.relativePathBytes, as: UTF8.self), decoded)
        }
        let dangling = try XCTUnwrap(records.first(where: {
            $0.relativePathBytes == Data("dangling-link".utf8)
        }))
        XCTAssertEqual(dangling.kind, .file)
        XCTAssertTrue(dangling.isSymbolicLink)
    }

    func testTinyByteBudgetsForceDeterministicMultiPassExternalMerge() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-merge-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-merge-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let input = (0 ..< 40).reversed().map { index in
            WorkspaceRootNamespaceRecord(
                relativePath: String(format: "Folder/file-%03d.swift", index),
                kind: .file,
                isSymbolicLink: false,
                fileSystemMode: 0o100644
            )
        } + [
            WorkspaceRootNamespaceRecord(relativePath: "A", kind: .directory, isSymbolicLink: false),
            WorkspaceRootNamespaceRecord(relativePath: "a", kind: .directory, isSymbolicLink: false),
            WorkspaceRootNamespaceRecord(relativePath: "Caf\u{00E9}", kind: .file, isSymbolicLink: false),
            WorkspaceRootNamespaceRecord(relativePath: "Cafe\u{0301}", kind: .file, isSymbolicLink: false)
        ]
        let resourcePolicy = policy(bufferBytes: 72, batchRecords: 2, openRuns: 2)

        let firstWriter = try store.makeWriter(identity: identity(root), resourcePolicy: resourcePolicy)
        try await firstWriter.append(contentsOf: input)
        let first = try await firstWriter.finish()
        let secondWriter = try store.makeWriter(identity: identity(root), resourcePolicy: resourcePolicy)
        try await secondWriter.append(contentsOf: input.reversed())
        let second = try await secondWriter.finish()
        let records = try readAll(first)

        XCTAssertGreaterThan(first.statistics.initialRunCount, 2)
        XCTAssertGreaterThan(first.statistics.mergePassCount, 1)
        XCTAssertLessThanOrEqual(first.statistics.peakBufferedRecordBytes, resourcePolicy.maximumBufferedRecordBytes)
        XCTAssertEqual(records.count, input.count)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(records.map(\.relativePathBytes), input.map(\.relativePathBytes).sorted(by: { $0.lexicographicallyPrecedes($1) }))
        XCTAssertNotEqual(input[input.count - 2].relativePathBytes, input[input.count - 1].relativePathBytes)
    }

    func testGenericSpillMigrationPreservesExactNamespaceFormatBytes() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-format-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-format-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let records = [
            WorkspaceRootNamespaceRecord(
                relativePath: "z-file",
                kind: .file,
                isSymbolicLink: false,
                fileSystemMode: 0o100755
            ),
            WorkspaceRootNamespaceRecord(
                relativePath: "a-directory",
                kind: .directory,
                isSymbolicLink: false,
                fileSystemMode: 0o040755
            )
        ]
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 32, batchRecords: 1, openRuns: 2)
        )
        try await writer.append(contentsOf: records)
        let lease = try await writer.finish()

        let sorted = records.sorted {
            $0.relativePathBytes.lexicographicallyPrecedes($1.relativePathBytes)
        }
        var expected = WorkspaceRootNamespaceManifestCodec.encodeHeader(lease.header)
        var digest = SHA256()
        digest.update(data: expected)
        var payloadByteCount: UInt64 = 0
        for record in sorted {
            let payload = try WorkspaceRootNamespaceManifestCodec.encodeRecord(record)
            let frame = try WorkspaceRootNamespaceManifestCodec.recordFrame(record)
            expected.append(frame)
            digest.update(data: frame)
            payloadByteCount += UInt64(payload.count)
        }
        let footer = WorkspaceRootNamespaceManifestFooter(
            recordCount: 2,
            fileCount: 1,
            directoryCount: 1,
            recordPayloadByteCount: payloadByteCount,
            digest: Data(digest.finalize())
        )
        expected.append(WorkspaceRootNamespaceManifestCodec.encodeFooter(footer))

        XCTAssertEqual(lease.header.schemaVersion, 1)
        XCTAssertEqual(lease.footer, footer)
        XCTAssertEqual(try Data(contentsOf: lease.fileURL), expected)
    }

    func testReaderFailsTerminallyWhenOpenArtifactIsMutatedOrTruncated() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-corrupt-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-corrupt-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let corruptLease = try await makeManifest(in: store, root: root, count: 12)
        let truncateLease = try await makeManifest(in: store, root: root, count: 12)
        let corruptReader = try corruptLease.makeReader()
        let truncateReader = try truncateLease.makeReader()

        try flipByte(in: corruptLease.fileURL)
        XCTAssertThrowsError(try corruptReader.next())
        XCTAssertEqual(corruptReader.validationState, .failed)
        XCTAssertThrowsError(try corruptReader.next()) { error in
            XCTAssertEqual(
                error as? WorkspaceRootNamespaceManifestError,
                .corrupt("reader validation already failed")
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: truncateLease.fileURL.path)
        let byteCount = try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
        let handle = try FileHandle(forUpdating: truncateLease.fileURL)
        try handle.truncate(atOffset: byteCount - 7)
        try handle.synchronize()
        try handle.close()
        XCTAssertThrowsError(try truncateReader.next())
        XCTAssertEqual(truncateReader.validationState, .failed)
    }

    func testForwardReaderRejectsPathReplacementAfterYieldingProvisionalRecord() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-replace-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-replace-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let lease = try await makeManifest(in: store, root: root, count: 12)
        let reader = try lease.makeReader()

        XCTAssertNotNil(try reader.next())
        XCTAssertEqual(reader.validationState, .reading)
        try replaceFileWithCopy(at: lease.fileURL)
        defer { try? FileManager.default.removeItem(at: lease.fileURL) }

        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(
                error as? WorkspaceRootNamespaceManifestError,
                .corrupt("artifact identity changed")
            )
        }
        XCTAssertEqual(reader.validationState, .failed)
        XCTAssertNil(reader.footer)
    }

    func testTransactionalForwardingAbortsDerivedArtifactOnSourceMutation() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-transaction-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-transaction-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let source = try await makeManifest(in: store, root: root, count: 12)
        let reader = try source.makeReader()
        let derivedWriter = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let gate = NamespaceManifestTransactionGate()
        await derivedWriter.setTransactionDidStageRecordHandlerForTesting {
            await gate.pause()
        }
        let forwarding = Task {
            try await derivedWriter.appendValidatedContents(from: reader)
        }
        await gate.waitUntilPaused()
        try flipLastByte(in: source.fileURL)
        await gate.release()

        do {
            try await forwarding.value
            XCTFail("Expected source mutation to abort transactional forwarding")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .corrupt("artifact identity changed"))
        }
        XCTAssertEqual(reader.validationState, .failed)
        XCTAssertEqual(store.activeArtifactURLs, [source.fileURL])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path),
            [source.fileURL.lastPathComponent]
        )
        do {
            _ = try await derivedWriter.finish()
            XCTFail("Expected the aborted derived writer to remain closed")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testTransactionalForwardingExclusivelyOwnsPristineReaderAcrossSuspension() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-exclusive-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-exclusive-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let source = try await makeManifest(in: store, root: root, count: 12)
        let reader = try source.makeReader()
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let competingWriter = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let gate = NamespaceManifestTransactionGate()
        await writer.setTransactionDidAcquireSourceHandlerForTesting {
            await gate.pause()
        }
        let forwarding = Task {
            try await writer.appendValidatedContents(from: reader)
        }
        await gate.waitUntilPaused()

        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(
                error as? WorkspaceRootNamespaceManifestError,
                .corrupt("reader is owned by an exclusive transaction")
            )
        }
        do {
            try await competingWriter.appendValidatedContents(from: reader)
            XCTFail("Expected competing transaction to reject the owned reader")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(
                error,
                .corrupt("reader is owned by an exclusive transaction")
            )
        }
        await competingWriter.cancel()

        await gate.release()
        try await forwarding.value
        let derived = try await writer.finish()
        XCTAssertEqual(try readAll(derived).count, 12)
    }

    func testConcurrentFinishCannotPublishUnverifiedTransactionalRecords() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-finish-race-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-finish-race-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let source = try await makeManifest(in: store, root: root, count: 12)
        let reader = try source.makeReader()
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let gate = NamespaceManifestTransactionGate()
        await writer.setTransactionDidStageRecordHandlerForTesting {
            await gate.pause()
        }
        let forwarding = Task {
            try await writer.appendValidatedContents(from: reader)
        }
        await gate.waitUntilPaused()

        do {
            _ = try await writer.finish()
            XCTFail("Expected finish to reject unverified transactional records")
        } catch let error as WorkspaceRootNamespaceManifestError {
            XCTAssertEqual(error, .closed)
        }
        XCTAssertEqual(store.activeArtifactURLs, [source.fileURL])

        await gate.release()
        try await forwarding.value
        XCTAssertEqual(store.activeArtifactURLs, [source.fileURL])
        let derived = try await writer.finish()
        XCTAssertEqual(try readAll(derived).count, 12)
    }

    func testConcurrentCancelCannotAbortIsolatedTransactionalForwarding() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cancel-race-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cancel-race-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let source = try await makeManifest(in: store, root: root, count: 12)
        let reader = try source.makeReader()
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        )
        let gate = NamespaceManifestTransactionGate()
        await writer.setTransactionDidStageRecordHandlerForTesting {
            await gate.pause()
        }
        let forwarding = Task {
            try await writer.appendValidatedContents(from: reader)
        }
        await gate.waitUntilPaused()

        await writer.cancel()
        XCTAssertEqual(store.activeArtifactURLs, [source.fileURL])

        await gate.release()
        try await forwarding.value
        let derived = try await writer.finish()
        XCTAssertEqual(try readAll(derived).count, 12)
    }

    func testGenericSpillDuplicateResolutionIsInvariantAcrossBatchBoundaries() async throws {
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-duplicates")
        let store = try SpillBackedSortedArtifactStore(
            directoryURL: storeRoot.appendingPathComponent("spill", isDirectory: true),
            defaultDirectoryStem: "unused"
        )
        let format = NamespaceManifestMaliciousSpillFormat(
            recordBound: 16,
            coalesceDuplicates: true
        )

        let sameBatchWriter = try store.makeWriter(
            format: format,
            header: Data([0x48]),
            resourcePolicy: maliciousSpillPolicy(bufferBytes: 64, batchRecords: 4)
        )
        try await sameBatchWriter.append(contentsOf: [
            Data([0x62]), Data([0x61]), Data([0x61])
        ])
        let sameBatch = try await sameBatchWriter.finish()

        let crossRunWriter = try store.makeWriter(
            format: format,
            header: Data([0x48]),
            resourcePolicy: maliciousSpillPolicy(bufferBytes: 64, batchRecords: 1)
        )
        try await crossRunWriter.append(contentsOf: [
            Data([0x62]), Data([0x61]), Data([0x61])
        ])
        let crossRun = try await crossRunWriter.finish()

        XCTAssertEqual(sameBatch.statistics.recordCount, 2)
        XCTAssertEqual(crossRun.statistics.recordCount, 2)
        XCTAssertEqual(
            try Data(contentsOf: sameBatch.fileURL),
            try Data(contentsOf: crossRun.fileURL)
        )
    }

    func testGenericSpillRejectsEncodedRecordsBeyondFormatAndByteBudgets() async throws {
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-malicious-record")
        let store = try SpillBackedSortedArtifactStore(
            directoryURL: storeRoot.appendingPathComponent("spill", isDirectory: true),
            defaultDirectoryStem: "unused"
        )
        let formatBoundWriter = try store.makeWriter(
            format: NamespaceManifestMaliciousSpillFormat(recordBound: 4),
            header: Data([0x48]),
            resourcePolicy: maliciousSpillPolicy(bufferBytes: 16)
        )
        do {
            try await formatBoundWriter.append(Data(repeating: 0x52, count: 5))
            XCTFail("Expected encoded record format-bound rejection")
        } catch let error as NamespaceManifestMaliciousSpillError {
            XCTAssertEqual(
                error,
                .failure(.corrupt("encoded record exceeds configured bound"))
            )
        }

        let byteBudgetWriter = try store.makeWriter(
            format: NamespaceManifestMaliciousSpillFormat(recordBound: 16),
            header: Data([0x48]),
            resourcePolicy: maliciousSpillPolicy(bufferBytes: 4)
        )
        do {
            try await byteBudgetWriter.append(Data(repeating: 0x52, count: 5))
            XCTFail("Expected encoded record byte-budget rejection")
        } catch let error as NamespaceManifestMaliciousSpillError {
            XCTAssertEqual(error, .failure(.resourceAdmission))
        }

        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testGenericSpillRejectsOversizedControlFramesAndIntegerOverflow() async throws {
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-malicious-frame")
        let store = try SpillBackedSortedArtifactStore(
            directoryURL: storeRoot.appendingPathComponent("spill", isDirectory: true),
            defaultDirectoryStem: "unused"
        )
        let policy = maliciousSpillPolicy(bufferBytes: 16)

        XCTAssertThrowsError(try store.makeWriter(
            format: NamespaceManifestMaliciousSpillFormat(
                recordBound: Int(UInt32.max)
            ),
            header: Data([0x48]),
            resourcePolicy: policy
        )) { error in
            XCTAssertEqual(
                error as? NamespaceManifestMaliciousSpillError,
                .failure(.invalidConfiguration)
            )
        }

        let oversizedHeader = try store.makeWriter(
            format: NamespaceManifestMaliciousSpillFormat(
                recordBound: 16,
                headerBound: 1
            ),
            header: Data([0x48, 0x48]),
            resourcePolicy: policy
        )
        try await oversizedHeader.append(Data([0x52]))
        do {
            _ = try await oversizedHeader.finish()
            XCTFail("Expected oversized header rejection")
        } catch let error as NamespaceManifestMaliciousSpillError {
            XCTAssertEqual(
                error,
                .failure(.corrupt("encoded header exceeds configured bound"))
            )
        }

        let oversizedFooter = try store.makeWriter(
            format: NamespaceManifestMaliciousSpillFormat(
                recordBound: 16,
                footerBound: 1,
                footerFrame: Data([0x46, 0x46])
            ),
            header: Data([0x48]),
            resourcePolicy: policy
        )
        try await oversizedFooter.append(Data([0x52]))
        do {
            _ = try await oversizedFooter.finish()
            XCTFail("Expected oversized footer rejection")
        } catch let error as NamespaceManifestMaliciousSpillError {
            XCTAssertEqual(
                error,
                .failure(.corrupt("encoded footer exceeds configured bound"))
            )
        }

        let format = NamespaceManifestMaliciousSpillFormat(recordBound: 16)
        XCTAssertThrowsError(try SpillBackedSortedArtifactChecked.uint32Length(
            Int(UInt32.max),
            label: "test record",
            format: format
        )) { error in
            XCTAssertEqual(
                error as? NamespaceManifestMaliciousSpillError,
                .failure(.corrupt("test record length overflow"))
            )
        }
        XCTAssertThrowsError(try SpillBackedSortedArtifactChecked.add(
            UInt64.max,
            1,
            label: "test catalog byte count",
            format: format
        )) { error in
            XCTAssertEqual(
                error as? NamespaceManifestMaliciousSpillError,
                .failure(.corrupt("test catalog byte count overflow"))
            )
        }

        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testFooterCountOverflowReturnsTypedCorruption() throws {
        let encoded = WorkspaceRootNamespaceManifestCodec.encodeFooter(
            WorkspaceRootNamespaceManifestFooter(
                recordCount: 0,
                fileCount: UInt64.max,
                directoryCount: 1,
                recordPayloadByteCount: 0,
                digest: Data(repeating: 0, count: SHA256.byteCount)
            )
        )
        let payload = Data(encoded.dropFirst())

        XCTAssertThrowsError(try WorkspaceRootNamespaceManifestCodec.decodeFooter(payload)) { error in
            XCTAssertEqual(
                error as? WorkspaceRootNamespaceManifestError,
                .corrupt("invalid footer counts")
            )
        }
    }

    func testCancellationAndLeaseReleaseRemoveAllPrivateArtifacts() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cancel-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cancel-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 64, batchRecords: 2, openRuns: 2)
        )
        for index in 0 ..< 20 {
            try await writer.append(WorkspaceRootNamespaceRecord(
                relativePath: "cancel/\(index)",
                kind: .file,
                isSymbolicLink: false
            ))
        }

        let cancelledFinish = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await writer.finish()
        }
        cancelledFinish.cancel()
        do {
            _ = try await cancelledFinish.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)

        var lease: WorkspaceRootNamespaceManifestLease? = try await makeManifest(in: store, root: root, count: 3)
        XCTAssertEqual(store.activeArtifactURLs, try [XCTUnwrap(lease).fileURL])
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    func testCleanupSerializesWriterCreationAndPreservesLeasedManifest() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cleanup-race-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-cleanup-race-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let cleanupEntered = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        let creationStarted = DispatchSemaphore(value: 0)
        let creationCompleted = DispatchSemaphore(value: 0)
        store.setCleanupWillEnumerateHandlerForTesting {
            cleanupEntered.signal()
            releaseCleanup.wait()
        }

        let cleanupTask = Task.detached { try store.cleanup() }
        XCTAssertEqual(cleanupEntered.wait(timeout: .now() + 2), .success)
        let manifestIdentity = try identity(root)
        let resourcePolicy = policy(bufferBytes: 64, batchRecords: 1, openRuns: 2)
        let writerTask = Task.detached {
            creationStarted.signal()
            let writer = try store.makeWriter(
                identity: manifestIdentity,
                resourcePolicy: resourcePolicy
            )
            creationCompleted.signal()
            return writer
        }
        XCTAssertEqual(creationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(creationCompleted.wait(timeout: .now() + 0.05), .timedOut)

        releaseCleanup.signal()
        try await cleanupTask.value
        let writer = try await writerTask.value
        store.setCleanupWillEnumerateHandlerForTesting(nil)
        try await writer.append(WorkspaceRootNamespaceRecord(
            relativePath: "kept.txt",
            kind: .file,
            isSymbolicLink: false
        ))
        let lease = try await writer.finish()

        try store.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
        XCTAssertEqual(try readAll(lease).map(\.relativePathBytes), [Data("kept.txt".utf8)])
    }

    func testOneRecordRunsKeepMergeSchedulingStateBounded() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-run-catalog-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-run-catalog-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let recordCount = 2048
        let resourcePolicy = policy(bufferBytes: 64, batchRecords: 1, openRuns: 3)
        let writer = try store.makeWriter(identity: identity(root), resourcePolicy: resourcePolicy)
        for index in (0 ..< recordCount).reversed() {
            try await writer.append(WorkspaceRootNamespaceRecord(
                relativePath: String(format: "one-record-run/%05d", index),
                kind: .file,
                isSymbolicLink: false
            ))
        }
        let lease = try await writer.finish()

        XCTAssertEqual(lease.statistics.initialRunCount, recordCount)
        XCTAssertGreaterThan(lease.statistics.mergePassCount, 1)
        XCTAssertLessThanOrEqual(lease.peakResidentScheduledRunCount, resourcePolicy.maximumOpenRuns)
        XCTAssertEqual(lease.footer.recordCount, UInt64(recordCount))
        var observedCount = 0
        let reader = try lease.makeReader()
        while try reader.next() != nil {
            observedCount += 1
        }
        XCTAssertEqual(observedCount, recordCount)
    }

    func testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-scale-root")
        let storeRoot = try temporaryRoots.makeRoot(suiteName: "WorkspaceRootNamespaceManifest-scale-store")
        let store = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("manifests", isDirectory: true)
        )
        let configuredCount = ProcessInfo.processInfo.environment["REPOPROMPT_NAMESPACE_MANIFEST_SCALE_ENTRY_COUNT"]
            .flatMap(Int.init) ?? 100_000
        XCTAssertGreaterThanOrEqual(configuredCount, 100_000)
        let resourcePolicy = policy(bufferBytes: 16 * 1024, batchRecords: 256, openRuns: 8)
        let writer = try store.makeWriter(identity: identity(root), resourcePolicy: resourcePolicy)

        var batch: [WorkspaceRootNamespaceRecord] = []
        batch.reserveCapacity(512)
        for index in (0 ..< configuredCount).reversed() {
            batch.append(WorkspaceRootNamespaceRecord(
                relativePath: String(format: "Synthetic/%07d/file.swift", index),
                kind: .file,
                isSymbolicLink: false,
                fileSystemMode: 0o100644
            ))
            if batch.count == 512 {
                try await writer.append(contentsOf: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await writer.append(contentsOf: batch) }
        let lease = try await writer.finish()

        XCTAssertEqual(lease.footer.recordCount, UInt64(configuredCount))
        XCTAssertGreaterThan(lease.statistics.initialRunCount, 100)
        XCTAssertLessThanOrEqual(lease.statistics.peakBufferedRecordBytes, resourcePolicy.maximumBufferedRecordBytes)
        var readCount = 0
        let reader = try lease.makeReader()
        while try reader.next() != nil {
            readCount += 1
        }
        XCTAssertEqual(readCount, configuredCount)
    }

    private func identity(_ root: URL) throws -> WorkspaceRootNamespaceManifestIdentity {
        try WorkspaceRootNamespaceManifestIdentity(
            root: WorkspaceRootNamespaceRootIdentity(rootURL: root),
            catalogPolicy: .canonicalDefaults
        )
    }

    private func policy(
        bufferBytes: Int,
        batchRecords: Int,
        openRuns: Int
    ) -> WorkspaceRootNamespaceManifestResourcePolicy {
        WorkspaceRootNamespaceManifestResourcePolicy(
            maximumBufferedRecordBytes: bufferBytes,
            maximumRecordsPerBatch: batchRecords,
            maximumRecordByteCount: 1024 * 1024,
            maximumOpenRuns: openRuns,
            minimumFreeDiskBytes: 0
        )
    }

    private func maliciousSpillPolicy(
        bufferBytes: Int,
        batchRecords: Int = 1
    ) -> SpillBackedSortedArtifactResourcePolicy {
        SpillBackedSortedArtifactResourcePolicy(
            maximumBufferedRecordBytes: bufferBytes,
            maximumRecordsPerBatch: batchRecords,
            maximumRecordByteCount: 64,
            maximumOpenRuns: 2,
            minimumFreeDiskBytes: 0
        )
    }

    private func makeManifest(
        in store: WorkspaceRootNamespaceManifestStore,
        root: URL,
        count: Int
    ) async throws -> WorkspaceRootNamespaceManifestLease {
        let writer = try store.makeWriter(
            identity: identity(root),
            resourcePolicy: policy(bufferBytes: 96, batchRecords: 3, openRuns: 2)
        )
        for index in (0 ..< count).reversed() {
            try await writer.append(WorkspaceRootNamespaceRecord(
                relativePath: String(format: "file-%03d", index),
                kind: .file,
                isSymbolicLink: false
            ))
        }
        return try await writer.finish()
    }

    private func readAll(
        _ lease: WorkspaceRootNamespaceManifestLease
    ) throws -> [WorkspaceRootNamespaceRecord] {
        let reader = try lease.makeReader()
        var records: [WorkspaceRootNamespaceRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        XCTAssertEqual(reader.footer, lease.footer)
        return records
    }

    private func flipByte(in url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
        try flipByte(in: url, at: byteCount / 2)
    }

    private func flipLastByte(in url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
        try flipByte(in: url, at: byteCount - 1)
    }

    private func flipByte(in url: URL, at offset: UInt64) throws {
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: offset)
        let byte = try XCTUnwrap(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.synchronize()
        try handle.close()
    }

    private func replaceFileWithCopy(at url: URL) throws {
        let replacement = url.deletingLastPathComponent().appendingPathComponent(
            ".replacement-\(UUID().uuidString.lowercased())"
        )
        try Data(contentsOf: url).write(to: replacement, options: .withoutOverwriting)
        guard chmod(replacement.path, 0o600) == 0 else {
            throw WorkspaceRootNamespaceManifestError.io(operation: "replacement-chmod", code: errno)
        }
        guard rename(replacement.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: replacement)
            throw WorkspaceRootNamespaceManifestError.io(operation: "replacement-rename", code: code)
        }
    }

    private func createRawFile(named bytes: [UInt8], in root: URL) throws -> Bool {
        let path = try rawPath(named: bytes, in: root)
        let descriptor = path.withUnsafeBufferPointer { buffer in
            creat(buffer.baseAddress, 0o600)
        }
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private func removeRawFile(named bytes: [UInt8], from root: URL) {
        guard let path = try? rawPath(named: bytes, in: root) else { return }
        path.withUnsafeBufferPointer { buffer in _ = unlink(buffer.baseAddress) }
    }

    private func rawPath(named bytes: [UInt8], in root: URL) throws -> [CChar] {
        try root.withUnsafeFileSystemRepresentation { rootPath -> [CChar] in
            guard let rootPath else {
                throw WorkspaceRootNamespaceManifestError.corrupt("test root has no filesystem representation")
            }
            var result = Array(UnsafeBufferPointer(start: rootPath, count: strlen(rootPath)))
            result.append(CChar(bitPattern: UInt8(ascii: "/")))
            result.append(contentsOf: bytes.map(CChar.init(bitPattern:)))
            result.append(0)
            return result
        }
    }
}

private enum NamespaceManifestMaliciousSpillError: Error, Equatable {
    case failure(SpillBackedSortedArtifactFailure)
}

private struct NamespaceManifestMaliciousSpillFormat: SpillBackedSortedArtifactFormat {
    let fileExtension = "malicious"
    let recordBound: Int
    let finalRecordBound: Int
    let maximumEncodedHeaderByteCount: Int
    let maximumEncodedFooterByteCount: Int
    let footerFrame: Data
    let coalesceDuplicates: Bool

    init(
        recordBound: Int,
        finalRecordBound: Int? = nil,
        headerBound: Int = 16,
        footerBound: Int = 16,
        footerFrame: Data = Data([0x46]),
        coalesceDuplicates: Bool = false
    ) {
        self.recordBound = recordBound
        self.finalRecordBound = finalRecordBound ?? recordBound
        maximumEncodedHeaderByteCount = headerBound
        maximumEncodedFooterByteCount = footerBound
        self.footerFrame = footerFrame
        self.coalesceDuplicates = coalesceDuplicates
    }

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        NamespaceManifestMaliciousSpillError.failure(failure)
    }

    func validate(_: Data, maximumRecordByteCount _: Int) throws {}

    func encodeRecord(_ record: Data) throws -> Data {
        record
    }

    func decodeRecord(_ payload: Data) throws -> Data {
        payload
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount _: Int) -> Int {
        recordBound
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount _: Int) -> Int {
        finalRecordBound
    }

    func ordering(_ lhs: Data, _ rhs: Data) -> SpillBackedSortedArtifactOrdering {
        if lhs == rhs { return .same }
        return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
    }

    func duplicateResolution(
        _: Data,
        _: Data
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        coalesceDuplicates ? .coalesce : .reject
    }

    func encodeFinalHeader(_ header: Data) throws -> Data {
        header
    }

    func encodeFinalRecord(_: Data, encodedRecord: Data) throws -> Data {
        encodedRecord
    }

    func makeFinalAccumulator() -> UInt64 {
        0
    }

    func accumulateFinalRecord(
        _: Data,
        encodedRecordByteCount _: Int,
        into accumulator: inout UInt64
    ) throws {
        accumulator += 1
    }

    func makeFinalFooter(accumulator _: UInt64, digest _: Data) throws -> Data {
        footerFrame
    }

    func encodeFinalFooter(_ footer: Data) throws -> Data {
        footer
    }
}

private actor NamespaceManifestTransactionGate {
    private var isPaused = false
    private var isReleased = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
