import Darwin
@testable import RepoPrompt
import XCTest

final class GitRawOutputSpoolTests: XCTestCase {
    func testSpoolStreamsBoundedChunksWithoutAggregateDataAndReleasesAfterReader() throws {
        let root = temporaryDirectory()
        var lease: GitRawOutputSpoolLease? = try {
            let spool = try GitRawOutputSpool(
                directoryURL: root,
                resourcePolicy: policy(maximumBytes: 1024, chunkBytes: 4)
            )
            try spool.append(Data("ab".utf8))
            try spool.append(Data("cd".utf8))
            return try spool.finish()
        }()
        let spoolFileURL = try XCTUnwrap(lease?.fileURL)
        var reader: GitRawOutputSpoolReader? = try lease?.makeReader()
        lease = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolFileURL.path))

        var received = Data()
        while let chunk = try reader?.nextChunk() {
            XCTAssertLessThanOrEqual(chunk.count, 3)
            received.append(chunk)
        }
        XCTAssertEqual(received, Data("abcd".utf8))
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSpoolByteAndDiskPoliciesFailClosedAsResourceAdmission() throws {
        let byteRoot = temporaryDirectory()
        let byteSpool = try GitRawOutputSpool(
            directoryURL: byteRoot,
            resourcePolicy: policy(maximumBytes: 3, chunkBytes: 4)
        )
        XCTAssertThrowsError(try byteSpool.append(Data("four".utf8))) { error in
            XCTAssertEqual(error as? GitRawOutputSpoolError, .resourceAdmission)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: byteRoot.path))

        let diskRoot = temporaryDirectory()
        XCTAssertThrowsError(try GitRawOutputSpool(
            directoryURL: diskRoot,
            resourcePolicy: GitRawOutputSpoolResourcePolicy(
                maximumSpoolByteCount: 1024,
                maximumWriteChunkByteCount: 4,
                readChunkByteCount: 3,
                minimumFreeDiskBytes: UInt64.max,
                activityTimeout: .seconds(1)
            )
        )) { error in
            XCTAssertEqual(error as? GitRawOutputSpoolError, .resourceAdmission)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskRoot.path))
    }

    func testReaderRejectsTruncationAndCancellation() async throws {
        let corruptionRoot = temporaryDirectory()
        let corruptionSpool = try GitRawOutputSpool(
            directoryURL: corruptionRoot,
            resourcePolicy: policy(maximumBytes: 1024, chunkBytes: 8)
        )
        try corruptionSpool.append(Data("payload".utf8))
        let corruptionLease = try corruptionSpool.finish()
        let descriptor = Darwin.open(corruptionLease.fileURL.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 2), 0)
        _ = Darwin.close(descriptor)
        XCTAssertThrowsError(try corruptionLease.makeReader()) { error in
            guard let spoolError = error as? GitRawOutputSpoolError,
                  case .corrupt = spoolError
            else {
                return XCTFail("expected descriptor-bound corruption, got \(error)")
            }
        }

        let cancellationRoot = temporaryDirectory()
        let cancellationSpool = try GitRawOutputSpool(
            directoryURL: cancellationRoot,
            resourcePolicy: policy(maximumBytes: 1024, chunkBytes: 8)
        )
        try cancellationSpool.append(Data("payload".utf8))
        let cancellationLease = try cancellationSpool.finish()
        let task = Task {
            let reader = try cancellationLease.makeReader()
            try await Task.sleep(for: .seconds(60))
            return try reader.nextChunk()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFinishPreservesTypedFinalizationCorruption() throws {
        let root = temporaryDirectory()
        let spool = try GitRawOutputSpool(
            directoryURL: root,
            resourcePolicy: policy(maximumBytes: 1024, chunkBytes: 8)
        )
        try spool.append(Data("payload".utf8))
        let descriptor = Darwin.open(spool.fileURL.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 2), 0)
        _ = Darwin.close(descriptor)

        XCTAssertThrowsError(try spool.finish()) { error in
            XCTAssertEqual(
                error as? GitRawOutputSpoolError,
                .corrupt("spool byte count mismatch")
            )
        }
    }

    private func policy(
        maximumBytes: UInt64,
        chunkBytes: Int
    ) -> GitRawOutputSpoolResourcePolicy {
        GitRawOutputSpoolResourcePolicy(
            maximumSpoolByteCount: maximumBytes,
            maximumWriteChunkByteCount: chunkBytes,
            readChunkByteCount: 3,
            minimumFreeDiskBytes: 0,
            activityTimeout: .seconds(1)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "git-raw-spool-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    }
}
