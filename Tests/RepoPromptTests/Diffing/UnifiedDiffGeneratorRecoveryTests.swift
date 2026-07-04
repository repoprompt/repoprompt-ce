@testable import RepoPrompt
import XCTest

final class UnifiedDiffGeneratorRecoveryTests: XCTestCase {
    func testGeneratedDiffHeadersNormalizeAbsolutePathsWithSpacesAndSummarizeCreatesDeletes() async throws {
        let createDiff = try await UnifiedDiffGenerator.build(
            oldLines: nil,
            newLines: [SwiftFixtureSource.emptyStruct("Created", trailingNewline: false)],
            filePath: "Repo Root/Sources/New File.swift"
        )
        XCTAssertEqual(createDiff, "--- /dev/null\n+++ b/Repo Root/Sources/New File.swift\n")

        let deleteDiff = try await UnifiedDiffGenerator.build(
            oldLines: ["final class Removed {}"],
            newLines: nil,
            filePath: "Repo Root/Sources/Removed File.swift"
        )
        XCTAssertEqual(deleteDiff, "--- a/Repo Root/Sources/Removed File.swift\n+++ /dev/null\n")
    }

    func testBuildFromEditChunksCarriesCumulativeDeltaAcrossSortedHunks() {
        let laterChunk = DiffChunk(
            lines: [
                DiffLine(content: " line10"),
                DiffLine(content: "-line11"),
                DiffLine(content: "+LINE11")
            ],
            startLine: 10
        )
        let earlierChunk = DiffChunk(
            lines: [
                DiffLine(content: " line1"),
                DiffLine(content: "-line2"),
                DiffLine(content: "+LINE2"),
                DiffLine(content: "+line2b")
            ],
            startLine: 1
        )

        let diff = UnifiedDiffGenerator.buildFromEditChunks(
            filePath: "Sources/File With Spaces.swift",
            chunks: [laterChunk, earlierChunk],
            startLineBase: .oneBased
        )

        XCTAssertTrue(diff.hasPrefix("--- a/Sources/File With Spaces.swift\n+++ b/Sources/File With Spaces.swift\n"))
        XCTAssertTrue(diff.contains("@@ -1,2 +1,3 @@"))
        XCTAssertTrue(diff.contains("@@ -10,2 +11,2 @@"))
        XCTAssertFalse(diff.contains("@@ -10,2 +10,2 @@"))
    }
}
