@testable import RepoPrompt
import XCTest

final class GitTargetEvidenceStreamingParserTests: XCTestCase {
    private let objectID = String(repeating: "a", count: 40)
    private let secondObjectID = String(repeating: "b", count: 40)

    func testTreeDeltaParsesArbitrarySplitsAndEmitsRenameSourceAndDestination() async throws {
        let sink = GitTargetEvidenceRecordSink<GitTargetTreeDeltaEvidenceRecord>()
        var parser = try GitTargetTreeDeltaStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await sink.append(record)
        }
        let output = Data(
            (
                ":100644 100644 \(objectID) \(secondObjectID) R100\0"
                    + "Root/old\tname\0Root/new\nname\0"
            ).utf8
        )
        for byte in output {
            try await parser.consume(Data([byte]))
        }
        try await parser.finish()

        let records = await sink.values
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].status, .renamedSource)
        XCTAssertEqual(records[0].repositoryRelativePathBytes, Data("Root/old\tname".utf8))
        XCTAssertNil(records[0].sourceRepositoryRelativePathBytes)
        XCTAssertNil(records[0].similarityScore)
        XCTAssertEqual(records[1].status, .renamed)
        XCTAssertEqual(records[1].repositoryRelativePathBytes, Data("Root/new\nname".utf8))
        XCTAssertEqual(records[1].sourceRepositoryRelativePathBytes, Data("Root/old\tname".utf8))
        XCTAssertEqual(records[1].similarityScore, 100)
    }

    func testIndexParsesStageAndFlagsWithoutChangingRawPathBytes() async throws {
        let sink = GitTargetEvidenceRecordSink<GitTargetIndexEvidenceRecord>()
        var parser = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await sink.append(record)
        }
        let output = Data("s 100644 \(objectID) 2\tRoot/tab\tand\nnewline\0".utf8)
        try await parser.consume(output.prefix(7))
        try await parser.consume(output.dropFirst(7).prefix(13))
        try await parser.consume(output.dropFirst(20))
        try await parser.finish()

        let indexRecords = await sink.values
        let record = try XCTUnwrap(indexRecords.first)
        XCTAssertEqual(record.stage, 2)
        XCTAssertTrue(record.assumeUnchanged)
        XCTAssertTrue(record.skipWorktree)
        XCTAssertEqual(record.repositoryRelativePathBytes, Data("Root/tab\tand\nnewline".utf8))
    }

    func testStatusType2PairsImmediatelyFollowingRawSourceFrame() async throws {
        let sink = GitTargetEvidenceRecordSink<GitTargetStatusEvidenceRecord>()
        var parser = try GitTargetStatusPorcelainV2StreamingParser(
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await sink.append(record)
        }
        let output = Data(
            (
                "# branch.head main\0"
                    + "2 R. N... 100644 100644 100644 \(objectID) \(secondObjectID) R087 Root/new\nname\0"
                    + "Root/old\tname\0"
            ).utf8
        )
        for split in output.chunkedForParserTest(widths: [1, 2, 7, 3, 19]) {
            try await parser.consume(split)
        }
        try await parser.finish()

        let statusRecords = await sink.values
        let record = try XCTUnwrap(statusRecords.first)
        XCTAssertEqual(record.kind, .renamed)
        XCTAssertEqual(record.repositoryRelativePathBytes, Data("Root/new\nname".utf8))
        XCTAssertEqual(record.sourceRepositoryRelativePathBytes, Data("Root/old\tname".utf8))
        XCTAssertEqual(record.similarityScore, 87)
        XCTAssertEqual(record.indexStatus, UInt8(ascii: "R"))
        XCTAssertEqual(record.workTreeStatus, UInt8(ascii: "."))
    }

    func testStatusPreservesOrdinaryUnmergedAndDirectoryMarkerSemantics() async throws {
        let sink = GitTargetEvidenceRecordSink<GitTargetStatusEvidenceRecord>()
        var parser = try GitTargetStatusPorcelainV2StreamingParser(
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await sink.append(record)
        }
        let ordinary = "1 M. N... 100644 100644 100644 \(objectID) \(secondObjectID) Root/file\tname\0"
        let unmerged = "u UU N... 100644 100644 100644 100644 a b c Root/conflict\nname\0"
        try await parser.consume(Data((ordinary + unmerged + "? Root/dir/\0! Root/ignored\0").utf8))
        try await parser.finish()

        let records = await sink.values
        XCTAssertEqual(records.map(\.kind), [.ordinary, .unmerged, .untracked, .ignored])
        XCTAssertEqual(records[0].repositoryRelativePathBytes, Data("Root/file\tname".utf8))
        XCTAssertEqual(records[1].repositoryRelativePathBytes, Data("Root/conflict\nname".utf8))
        XCTAssertEqual(records[1].conflictStage3ObjectIDBytes, Data("c".utf8))
        XCTAssertEqual(records[2].repositoryRelativePathBytes, Data("Root/dir".utf8))
        XCTAssertTrue(records[2].isDirectoryMarker)
        XCTAssertFalse(records[3].isDirectoryMarker)
    }

    func testFinishRejectsMissingNULAndMissingType2Source() async throws {
        var missingNUL = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { _ in }
        try await missingNUL.consume(Data("H 100644 \(objectID) 0\tRoot/file".utf8))
        do {
            try await missingNUL.finish()
            XCTFail("Expected unterminated output to fail")
        } catch let error as GitWorktreeInitializationError {
            guard case .malformedOutput = error else { return XCTFail("Unexpected error: \(error)") }
        }

        var missingSource = try GitTargetStatusPorcelainV2StreamingParser(
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { _ in }
        try await missingSource.consume(Data(
            "2 R. N... 100644 100644 100644 a b R100 Root/new\0".utf8
        ))
        do {
            try await missingSource.finish()
            XCTFail("Expected the absent type-2 source path to fail")
        } catch let error as GitWorktreeInitializationError {
            guard case .malformedOutput = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testStatusRejectsInvalidType2SourceSiblingPrefix() async throws {
        var sibling = try GitTargetStatusPorcelainV2StreamingParser(
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { _ in }
        do {
            try await sibling.consume(Data(
                "2 R. N... 100644 100644 100644 a b R100 Root/new\0RootSibling/old\0".utf8
            ))
            XCTFail("Expected sibling-prefix source to fail")
        } catch let error as GitWorktreeInitializationError {
            guard case .malformedOutput = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testParsersPreserveInvalidUTF8PathBytesAcrossTreeIndexAndStatus() async throws {
        let treeSink = GitTargetEvidenceRecordSink<GitTargetTreeDeltaEvidenceRecord>()
        var treeParser = try GitTargetTreeDeltaStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await treeSink.append(record)
        }
        let treePath = Data(Array("Root/tree-".utf8) + [0xFF])
        var treeOutput = Data(
            ":100644 100644 \(objectID) \(secondObjectID) M\0".utf8
        )
        treeOutput.append(treePath)
        treeOutput.append(0)
        try await treeParser.consume(treeOutput)
        try await treeParser.finish()
        let treeRecords = await treeSink.values
        XCTAssertEqual(treeRecords.first?.repositoryRelativePathBytes, treePath)

        let indexSink = GitTargetEvidenceRecordSink<GitTargetIndexEvidenceRecord>()
        var indexParser = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await indexSink.append(record)
        }
        let indexPath = Data(Array("Root/index-".utf8) + [0xFE])
        var indexOutput = Data("H 100644 \(objectID) 0\t".utf8)
        indexOutput.append(indexPath)
        indexOutput.append(0)
        try await indexParser.consume(indexOutput)
        try await indexParser.finish()
        let indexRecords = await indexSink.values
        XCTAssertEqual(indexRecords.first?.repositoryRelativePathBytes, indexPath)

        let statusSink = GitTargetEvidenceRecordSink<GitTargetStatusEvidenceRecord>()
        var statusParser = try GitTargetStatusPorcelainV2StreamingParser(
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await statusSink.append(record)
        }
        let destination = Data(Array("Root/new-".utf8) + [0xFD])
        let source = Data(Array("Root/old-".utf8) + [0xFC])
        var statusOutput = Data(
            "2 R. N... 100644 100644 100644 \(objectID) \(secondObjectID) R100 ".utf8
        )
        statusOutput.append(destination)
        statusOutput.append(0)
        statusOutput.append(source)
        statusOutput.append(0)
        try await statusParser.consume(statusOutput)
        try await statusParser.finish()

        let statusRecords = await statusSink.values
        let statusRecord = try XCTUnwrap(statusRecords.first)
        XCTAssertEqual(statusRecord.repositoryRelativePathBytes, destination)
        XCTAssertEqual(statusRecord.sourceRepositoryRelativePathBytes, source)
    }

    func testTreeDeltaRejectsStructurallyIncompleteRenameAndPathPolicyOverflow() async throws {
        var incomplete = try GitTargetTreeDeltaStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { _ in }
        try await incomplete.consume(Data(
            ":100644 100644 \(objectID) \(secondObjectID) R100\0Root/old\0".utf8
        ))
        do {
            try await incomplete.finish()
            XCTFail("Expected missing rename destination to fail")
        } catch let error as GitWorktreeInitializationError {
            guard case .malformedOutput = error else { return XCTFail("Unexpected error: \(error)") }
        }

        var bounded = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root"),
            pathPolicy: .init(maximumPathBytes: 8, maximumDepth: 2)
        ) { _ in }
        do {
            try await bounded.consume(Data("H 100644 \(objectID) 0\tRoot/toolong\0".utf8))
            XCTFail("Expected path byte policy rejection")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .pathLimitExceeded)
        }
    }

    func testEmissionIsDirectAndWriterFailureStopsParsing() async throws {
        let sink = GitTargetEvidenceRecordSink<GitTargetIndexEvidenceRecord>()
        var parser = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { record in
            await sink.append(record)
            throw GitTargetEvidenceParserTestError.writerRejected
        }
        do {
            try await parser.consume(Data("H 100644 \(objectID) 0\tRoot/file\0".utf8))
            XCTFail("Expected writer failure")
        } catch GitTargetEvidenceParserTestError.writerRejected {
            let emittedCount = await sink.values.count
            XCTAssertEqual(emittedCount, 1)
        }
    }

    func testCancellationInterruptsDirectWriterEmission() async throws {
        let entered = GitTargetEvidenceAsyncSignal()
        let objectID = objectID
        let task = Task {
            var parser = try GitTargetIndexStreamingParser(
                objectFormat: .sha1,
                rootPrefix: GitRepositoryRelativeRootPrefix("Root")
            ) { _ in
                await entered.signal()
                try await Task.sleep(for: .seconds(60))
            }
            try await parser.consume(Data("H 100644 \(objectID) 0\tRoot/file\0".utf8))
        }
        await entered.wait()
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testStreamsBeyondFormerTenThousandRecordLimitWithoutRetainingRecords() async throws {
        try await assertIndexScale(recordCount: 10001)
    }

    func testOptionalOneMillionRecordStreamingScale() async throws {
        guard ProcessInfo.processInfo.environment["RPCE_GIT_TARGET_EVIDENCE_SCALE_1M"] == "1" else {
            throw XCTSkip("Set RPCE_GIT_TARGET_EVIDENCE_SCALE_1M=1 to run the 1M parser scale hook")
        }
        try await assertIndexScale(recordCount: 1_000_000)
    }

    private func assertIndexScale(recordCount: Int) async throws {
        let counter = GitTargetEvidenceLockedCounter()
        var parser = try GitTargetIndexStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("Root")
        ) { _ in
            counter.increment()
        }
        for index in 0 ..< recordCount {
            try await parser.consume(Data("H 100644 \(objectID) 0\tRoot/file-\(index)\0".utf8))
        }
        try await parser.finish()
        XCTAssertEqual(counter.value, recordCount)
    }
}

private enum GitTargetEvidenceParserTestError: Error {
    case writerRejected
}

private actor GitTargetEvidenceRecordSink<Record: Sendable> {
    private(set) var values: [Record] = []

    func append(_ record: Record) {
        values.append(record)
    }
}

private final class GitTargetEvidenceLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private actor GitTargetEvidenceAsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private extension Data {
    func chunkedForParserTest(widths: [Int]) -> [Data] {
        precondition(!widths.isEmpty && widths.allSatisfy { $0 > 0 })
        var result: [Data] = []
        var offset = 0
        var widthIndex = 0
        while offset < count {
            let width = Swift.min(widths[widthIndex % widths.count], count - offset)
            result.append(self[offset ..< offset + width])
            offset += width
            widthIndex += 1
        }
        return result
    }
}
