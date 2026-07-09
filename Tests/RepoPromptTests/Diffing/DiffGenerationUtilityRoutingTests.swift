@testable import RepoPromptApp
import XCTest

final class DiffGenerationUtilityRoutingTests: XCTestCase {
    func testReplaceAllBypassesDuplicateMatchAmbiguityAndAppliesCumulativeOffsets() async throws {
        let rows = [
            (
                label: "positive delta",
                fileContent: ["before", "same", "middle", "same", "after"],
                searchBlock: ["same"],
                replacement: ["replacement", "extra"],
                expected: ["before", "replacement", "extra", "middle", "replacement", "extra", "after"]
            ),
            (
                label: "negative delta",
                fileContent: ["before", "same", "remove", "middle", "same", "remove", "after"],
                searchBlock: ["same", "remove"],
                replacement: ["replacement"],
                expected: ["before", "replacement", "middle", "replacement", "after"]
            )
        ]

        for row in rows {
            do {
                _ = try await DiffGenerationUtility.generateDiff(
                    fileContent: row.fileContent,
                    lineIndexMap: nil,
                    startSelector: nil,
                    endSelector: nil,
                    searchBlock: row.searchBlock,
                    newContent: row.replacement,
                    action: .modify,
                    diffPrecision: .high,
                    mcpAmbiguityCheck: true,
                    replaceAll: false
                )
                XCTFail("Expected duplicate search blocks to be ambiguous without replaceAll: \(row.label)")
            } catch let error as DiffGenerationError {
                guard case .ambiguousMatch = error else {
                    return XCTFail("Expected ambiguity error for \(row.label), got \(error)")
                }
            }

            let chunks = try await DiffGenerationUtility.generateDiff(
                fileContent: row.fileContent,
                lineIndexMap: nil,
                startSelector: nil,
                endSelector: nil,
                searchBlock: row.searchBlock,
                newContent: row.replacement,
                action: .modify,
                diffPrecision: .high,
                mcpAmbiguityCheck: true,
                replaceAll: true
            )
            let result = try DiffChunkTextApplier.apply(
                chunks: chunks,
                to: row.fileContent.joined(separator: "\n")
            )

            XCTAssertEqual(result, row.expected.joined(separator: "\n"), row.label)
        }
    }
}
