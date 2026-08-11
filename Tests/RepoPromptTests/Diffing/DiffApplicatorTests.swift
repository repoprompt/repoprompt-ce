import RepoPromptDomainRuntime
import XCTest

final class DiffApplicatorTests: XCTestCase {
    func testApplyReconstructsMixedChunkAndPreservesUntouchedLines() throws {
        let chunk = DiffChunk(
            lines: [
                DiffLine(content: " context"),
                DiffLine(content: "-remove"),
                DiffLine(content: "+replacement"),
                DiffLine(content: "+extra")
            ],
            startLine: 1
        )

        let result = try DiffApplicator.apply(
            chunk,
            to: ["before", "context", "remove", "after"],
            startingAt: chunk.startLine
        )

        XCTAssertEqual(result, ["before", "context", "replacement", "extra", "after"])
    }

    func testApplyReturnsPartialResultWhenChunkRunsPastContent() throws {
        let chunk = DiffChunk(
            lines: [
                DiffLine(content: "+inserted"),
                DiffLine(content: " missing-context"),
                DiffLine(content: "+not-applied")
            ],
            startLine: 1
        )

        let result = try DiffApplicator.apply(chunk, to: ["before"], startingAt: chunk.startLine)

        XCTAssertEqual(result, ["before", "inserted"])
    }

    func testApplyRejectsStartLinesOutsideContentBounds() {
        let chunk = DiffChunk(lines: [], startLine: 0)

        assertOutOfBounds(startLine: -1, content: ["line"], chunk: chunk)
        assertOutOfBounds(startLine: 2, content: ["line"], chunk: chunk)
    }

    func testRevertRestoresRemovalOrder() throws {
        let chunk = DiffChunk(
            lines: [
                DiffLine(content: "-first"),
                DiffLine(content: "-second")
            ],
            startLine: 1
        )

        let result = try DiffApplicator.revert(
            chunk,
            from: ["before", "after"],
            startingAt: chunk.startLine
        )

        XCTAssertEqual(result, ["before", "first", "second", "after"])
    }

    func testRevertPreservesMixedOperationAndBoundarySemantics() throws {
        let chunk = DiffChunk(
            lines: [
                DiffLine(content: " context"),
                DiffLine(content: "-removed"),
                DiffLine(content: "+added")
            ],
            startLine: 1
        )

        let result = try DiffApplicator.revert(
            chunk,
            from: ["before", "context", "added", "after"],
            startingAt: chunk.startLine
        )

        XCTAssertEqual(result, ["before", "context", "removed", "after"])
        assertRevertOutOfBounds(startLine: -1, content: ["line"], chunk: chunk)
        assertRevertOutOfBounds(startLine: 2, content: ["line"], chunk: chunk)
    }

    func testRevertReturnsEmptyBeforeValidatingStartLine() {
        let chunk = DiffChunk(lines: [], startLine: 0)

        do {
            let result = try DiffApplicator.revert(chunk, from: [], startingAt: -1)
            XCTAssertEqual(result, [])
        } catch {
            XCTFail("Expected empty content to return before start-line validation, got \(error)")
        }
    }

    private func assertOutOfBounds(startLine: Int, content: [String], chunk: DiffChunk) {
        XCTAssertThrowsError(try DiffApplicator.apply(chunk, to: content, startingAt: startLine)) { error in
            guard case let DiffApplicationError.outOfBounds(line, contentSize) = error else {
                return XCTFail("Expected outOfBounds, got \(error)")
            }
            XCTAssertEqual(line, startLine)
            XCTAssertEqual(contentSize, content.count)
        }
    }

    private func assertRevertOutOfBounds(startLine: Int, content: [String], chunk: DiffChunk) {
        XCTAssertThrowsError(try DiffApplicator.revert(chunk, from: content, startingAt: startLine)) { error in
            guard case let DiffApplicationError.outOfBounds(line, contentSize) = error else {
                return XCTFail("Expected outOfBounds, got \(error)")
            }
            XCTAssertEqual(line, startLine)
            XCTAssertEqual(contentSize, content.count)
        }
    }
}
