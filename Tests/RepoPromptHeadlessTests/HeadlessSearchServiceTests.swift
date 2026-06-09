import Darwin
import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessSearchServiceTests: XCTestCase {
    func testCatalogTruncationRequiresEligibleOverflowEntry() throws {
        try withFixture { fixture in
            try fixture.write("only.txt", contents: "visible")
            try fixture.write(".git/ignored.txt", contents: "ignored")

            let complete = try HeadlessFileCatalog().scan(roots: [fixture.root], maxEntries: 2)
            XCTAssertEqual(complete.entries.count, 2)
            XCTAssertEqual(complete.entryLimit, 2)
            XCTAssertFalse(complete.wasTruncated)

            try fixture.write("overflow.txt", contents: "visible")
            let truncated = try HeadlessFileCatalog().scan(roots: [fixture.root], maxEntries: 2)
            XCTAssertEqual(truncated.entries.count, 2)
            XCTAssertTrue(truncated.wasTruncated)
        }
    }

    func testBothModeUsesSharedReturnBudgetAndReportsCompleteTotals() throws {
        try withSearchFixture { fixture in
            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "needle",
                    "mode": "both",
                    "regex": false,
                    "max_results": 2
                ]
            )

            XCTAssertEqual(result.structured["total_path_matches"] as? Int, 1)
            XCTAssertEqual(result.structured["total_content_matches"] as? Int, 4)
            XCTAssertEqual(result.structured["total_matches"] as? Int, 5)
            XCTAssertEqual(result.structured["returned_matches"] as? Int, 2)
            XCTAssertEqual(result.structured["omitted"] as? Int, 3)
            XCTAssertEqual(result.structured["count_only"] as? Bool, false)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, true)
            XCTAssertEqual(result.structured["totals_are_lower_bounds"] as? Bool, false)

            let pathMatches = try XCTUnwrap(result.structured["path_matches"] as? [[String: Any]])
            let contentMatches = try XCTUnwrap(result.structured["content_matches"] as? [[String: Any]])
            XCTAssertEqual(pathMatches.count + contentMatches.count, 2)
        }
    }

    func testCountOnlyReturnsNoArraysAndReportsOnlyMatchesBeyondMaxResultsAsOmitted() throws {
        try withSearchFixture { fixture in
            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "needle",
                    "mode": "both",
                    "regex": false,
                    "max_results": 1,
                    "count_only": true
                ]
            )

            XCTAssertEqual(result.structured["total_matches"] as? Int, 5)
            XCTAssertEqual(result.structured["returned_matches"] as? Int, 0)
            XCTAssertEqual(result.structured["omitted"] as? Int, 4)
            XCTAssertEqual(result.structured["count_only"] as? Bool, true)
            XCTAssertEqual((result.structured["path_matches"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual((result.structured["content_matches"] as? [[String: Any]])?.count, 0)
        }
    }

    func testCatalogCapMakesTotalsExplicitLowerBounds() throws {
        try withFixture { fixture in
            try fixture.write("a.txt", contents: "none")
            try fixture.write("b.txt", contents: "none")

            let result = try HeadlessSearchService(maxCatalogEntries: 2).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "absent",
                    "mode": "path",
                    "regex": false
                ]
            )

            XCTAssertEqual(result.structured["catalog_entries_scanned"] as? Int, 2)
            XCTAssertEqual(result.structured["catalog_entry_limit"] as? Int, 2)
            XCTAssertEqual(result.structured["catalog_scan_count"] as? Int, 1)
            XCTAssertEqual(result.structured["catalog_truncated"] as? Bool, true)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)
            XCTAssertEqual(result.structured["totals_are_lower_bounds"] as? Bool, true)
            XCTAssertTrue(result.summary.contains("eligible entries remain unscanned"))
        }
    }

    func testCatalogReadFailureMakesTotalsExplicitLowerBounds() throws {
        try withFixture { fixture in
            try fixture.write("unreadable.txt", contents: "needle")
            let unreadable = fixture.directory.appendingPathComponent("unreadable.txt")
            XCTAssertEqual(Darwin.chmod(unreadable.path, 0), 0)
            defer { _ = Darwin.chmod(unreadable.path, S_IRUSR | S_IWUSR) }

            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "needle", "mode": "both", "regex": false]
            )

            XCTAssertEqual(result.structured["catalog_skipped_entries"] as? Int, 1)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)
            XCTAssertTrue(result.summary.contains("catalog entry or traversal error"))
        }
    }

    func testDirectoryExpansionRejectsTruncatedSubset() throws {
        try withFixture { fixture in
            try fixture.write("a.txt", contents: "a")
            try fixture.write("b.txt", contents: "b")
            let directory = try fixture.resolver.resolve("Fixture")

            XCTAssertThrowsError(try HeadlessFileCatalog().filesUnder(directory, maxFiles: 1)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Directory expansion exceeded"))
            }
        }
    }

    func testContentFileAndByteBudgetsStopBeforeUnboundedReads() throws {
        try withFixture { fixture in
            for index in 0 ..< 12 {
                try fixture.write(String(format: "%03d.txt", index), contents: "0123456789")
            }

            var fileLimits = HeadlessSearchLimits()
            fileLimits.maxContentFiles = 3
            fileLimits.maxContentBytes = 1000
            fileLimits.maxElapsedNanoseconds = 60_000_000_000
            fileLimits.maxMatcherWorkBytes = 1_000_000
            let fileLimited = try HeadlessSearchService(limits: fileLimits).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "absent", "mode": "content", "regex": false]
            )

            XCTAssertEqual(fileLimited.structured["content_files_attempted"] as? Int, 3)
            XCTAssertEqual(fileLimited.structured["content_files_scanned"] as? Int, 3)
            XCTAssertEqual(fileLimited.structured["budget_exhaustion_reason"] as? String, "content_file_limit")
            XCTAssertEqual(fileLimited.structured["totals_complete"] as? Bool, false)

            var byteLimits = fileLimits
            byteLimits.maxContentFiles = 12
            byteLimits.maxContentBytes = 15
            let byteLimited = try HeadlessSearchService(limits: byteLimits).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "absent", "mode": "content", "regex": false]
            )

            XCTAssertEqual(byteLimited.structured["content_files_attempted"] as? Int, 1)
            XCTAssertEqual(byteLimited.structured["content_bytes_considered"] as? Int, 10)
            XCTAssertEqual(byteLimited.structured["budget_exhaustion_reason"] as? String, "content_byte_limit")
        }
    }

    func testLargeTreeStopsAtDeterministicElapsedBudget() throws {
        try withFixture { fixture in
            for index in 0 ..< 200 {
                try fixture.write(String(format: "%03d.txt", index), contents: "content")
            }
            let clock = SteppingMonotonicClock(step: 1_000_000)
            var limits = HeadlessSearchLimits()
            limits.maxElapsedNanoseconds = 12_000_000
            limits.maxContentFiles = 200
            limits.maxContentBytes = 10000
            limits.maxMatcherWorkBytes = 1_000_000

            let result = try HeadlessSearchService(limits: limits, monotonicNow: clock.now).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "absent", "mode": "content", "regex": false]
            )

            XCTAssertEqual(result.structured["budget_exhaustion_reason"] as? String, "time_limit")
            XCTAssertEqual(result.structured["budget_exhausted"] as? Bool, true)
            XCTAssertEqual(result.structured["catalog_truncated"] as? Bool, true)
            XCTAssertLessThan(result.structured["catalog_entries_scanned"] as? Int ?? 200, 200)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)
        }
    }

    func testRegexSubjectAndEngineWorkAreBounded() throws {
        try withFixture { fixture in
            try fixture.write("long.txt", contents: String(repeating: "a", count: 256))
            var limits = HeadlessSearchLimits()
            limits.maxRegexSubjectBytes = 32
            limits.maxElapsedNanoseconds = 60_000_000_000
            limits.maxMatcherWorkBytes = 1_000_000

            let result = try HeadlessSearchService(limits: limits).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "a+$", "mode": "content", "regex": true]
            )

            XCTAssertEqual(result.structured["budget_exhaustion_reason"] as? String, "regex_subject_limit")
            XCTAssertEqual(result.structured["total_content_matches"] as? Int, 0)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)

            XCTAssertThrowsError(try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "^(a+)+b$", "mode": "content", "regex": true]
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsafe regular expression"))
            }
        }
    }

    func testSearchObservesTaskCancellationDuringCatalogTraversal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessSearchCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = HeadlessAllowedRoot(
            id: UUID(),
            name: "Fixture",
            path: directory.path,
            resolvedPath: directory.resolvingSymlinksInPath().standardizedFileURL.path,
            addedAt: Date()
        )
        let fixture = Fixture(directory: directory, root: root)
        for index in 0 ..< 100 {
            try fixture.write(String(format: "%03d.txt", index), contents: "content")
        }
        let clock = BlockingMonotonicClock()
        var limits = HeadlessSearchLimits()
        limits.maxElapsedNanoseconds = 60_000_000_000
        let service = HeadlessSearchService(limits: limits, monotonicNow: clock.now)
        let task = Task.detached {
            try service.search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "absent", "mode": "content", "regex": false]
            )
        }

        XCTAssertEqual(clock.entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        clock.resume.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func withSearchFixture(_ body: (Fixture) throws -> Void) throws {
        try withFixture { fixture in
            try fixture.write("alpha.txt", contents: "needle\nneedle\n")
            try fixture.write("beta.txt", contents: "needle\n")
            try fixture.write("needle-name.txt", contents: "needle\n")
            try body(fixture)
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = HeadlessAllowedRoot(
            id: UUID(),
            name: "Fixture",
            path: directory.path,
            resolvedPath: directory.resolvingSymlinksInPath().standardizedFileURL.path,
            addedAt: Date()
        )
        try body(Fixture(directory: directory, root: root))
    }

    private struct Fixture {
        let directory: URL
        let root: HeadlessAllowedRoot

        var resolver: HeadlessPathResolver {
            HeadlessPathResolver(roots: [root])
        }

        func write(_ relativePath: String, contents: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
}

private final class SteppingMonotonicClock {
    private var value: UInt64 = 0
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    func now() -> UInt64 {
        defer { value += step }
        return value
    }
}

private final class BlockingMonotonicClock: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0

    func now() -> UInt64 {
        lock.lock()
        callCount += 1
        let shouldBlock = callCount == 2
        lock.unlock()
        if shouldBlock {
            entered.signal()
            resume.wait()
        }
        return 0
    }
}
