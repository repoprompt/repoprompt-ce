import Foundation
@testable import RepoPrompt
import XCTest

final class ContextBuilderAssistantOutputAccumulatorTests: XCTestCase {
    func testMessageBoundaryAccumulationPreservesExactOutput() {
        var accumulator = ContextBuilderAssistantOutputAccumulator()

        accumulator.append("First", messageID: "message-a")
        accumulator.append(" chunk", messageID: "message-a")
        accumulator.append("Second", messageID: "message-b")
        accumulator.append("\nThird", messageID: "message-c")

        XCTAssertEqual(
            accumulator.fullOutput(),
            "First chunk\n\nSecond\n\nThird"
        )
    }

    func testIncrementalPreviewMatchesLegacyWholeOutputCompaction() {
        var accumulator = ContextBuilderAssistantOutputAccumulator()
        let chunks = [
            "  Leading\n",
            " whitespace\tand ",
            String(repeating: "x", count: 90),
            "\n",
            String(repeating: "y", count: 90),
            " trailing   "
        ]
        var exact = ""

        for chunk in chunks {
            accumulator.append(chunk)
            exact += chunk
            XCTAssertEqual(accumulator.preview, legacyPreview(exact))
        }
    }

    func testPreviewThresholdsRemainEquivalent() {
        var accumulator = ContextBuilderAssistantOutputAccumulator()
        let first = String(repeating: "a", count: 160)
        accumulator.append(first)
        XCTAssertEqual(accumulator.preview, first)

        accumulator.append("b")
        XCTAssertEqual(accumulator.preview, "…" + String(first.suffix(158)) + "b")
        XCTAssertEqual(accumulator.preview?.count, 160)
    }

    func testAuthoritativeFinalContentReplacesStreamedOutput() {
        var accumulator = ContextBuilderAssistantOutputAccumulator()
        accumulator.append("partial response", messageID: "stream")

        accumulator.replace(with: "authoritative\n final")

        XCTAssertEqual(accumulator.fullOutput(), "authoritative\n final")
        XCTAssertEqual(accumulator.preview, "authoritative final")
    }

    func testLargeOutputStaysChunkedUntilOneTerminalMaterialization() {
        var accumulator = ContextBuilderAssistantOutputAccumulator()
        let chunkCount = 20000

        for _ in 0 ..< chunkCount {
            accumulator.append("x")
        }

        XCTAssertEqual(accumulator.accumulatedCharacterCount, chunkCount)
        XCTAssertEqual(accumulator.fullOutputMaterializationCount, 0)
        XCTAssertEqual(accumulator.preview?.count, 160)

        let output = accumulator.fullOutput()
        XCTAssertEqual(output?.count, chunkCount)
        XCTAssertEqual(accumulator.fullOutputMaterializationCount, 1)
    }

    private func legacyPreview(_ output: String) -> String? {
        let compacted = output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= ContextBuilderAssistantOutputAccumulator.previewLimit {
            return compacted
        }
        return "…" + String(compacted.suffix(ContextBuilderAssistantOutputAccumulator.previewLimit - 1))
    }
}
