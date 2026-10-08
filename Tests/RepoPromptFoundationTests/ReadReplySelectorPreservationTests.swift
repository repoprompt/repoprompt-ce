import Foundation
@testable import RepoPromptFoundation
import XCTest

final class ReadReplySelectorPreservationTests: XCTestCase {
    func testReadReplySelectorRetainsWhitespaceControlsAndUnicodeForFullAndSlice() throws {
        for path in [" Sources/API.swift ", "Sources/line\nbreak.swift", "Sources/tab\tname.swift", "Sources/folder／file.swift", "Sources/café.swift"] {
            let fullReply = ReadReplySelectionPolicy.Metadata(totalLines: 8, firstLine: 1, lastLine: 8, displayPath: path)
            let fullSelection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: fullReply, fallbackPath: "fallback.swift"))
            guard case let .full(fullPath) = fullSelection else { return XCTFail("Expected full-file selection") }
            XCTAssertEqual(Data(fullPath.utf8), Data(path.utf8))
            let sliceReply = ReadReplySelectionPolicy.Metadata(totalLines: 8, firstLine: 2, lastLine: 4, displayPath: path)
            let sliceSelection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: sliceReply, fallbackPath: "fallback.swift"))
            guard case let .slice(entry) = sliceSelection else { return XCTFail("Expected slice selection") }
            XCTAssertEqual(Data(entry.path.utf8), Data(path.utf8))
            XCTAssertEqual(entry.ranges, [.init(start: 2, end: 4)])
        }
    }

    func testReadReplySliceCannotBorrowFullSelectionFromWhitespaceNeighbor() throws {
        let wanted = "Sources/API.swift "
        let neighbor = "Sources/API.swift"
        let reply = ReadReplySelectionPolicy.Metadata(totalLines: 8, firstLine: 2, lastLine: 4, displayPath: wanted)
        let selection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: reply, fallbackPath: neighbor))
        let neighborOutcome = ReadReplySelectionPolicy.preserveExistingFullFileSelection(selection, existingFullPaths: [neighbor])
        guard case let .slice(entry) = neighborOutcome else { return XCTFail("Whitespace neighbor erased the requested slice") }
        XCTAssertEqual(Data(entry.path.utf8), Data(wanted.utf8))
        XCTAssertEqual(entry.ranges, [.init(start: 2, end: 4)])
        let exactOutcome = ReadReplySelectionPolicy.preserveExistingFullFileSelection(selection, existingFullPaths: [wanted])
        guard case let .full(path) = exactOutcome else { return XCTFail("Exact existing full-file selector was not retained") }
        XCTAssertEqual(Data(path.utf8), Data(wanted.utf8))
    }

    func testReadReplyInstructionExclusionDoesNotRetargetWhitespaceNeighbor() throws {
        for exact in ["AGENTS.md", "Sources/agents.MD"] {
            let reply = ReadReplySelectionPolicy.Metadata(totalLines: 3, firstLine: 1, lastLine: 3, displayPath: exact)
            XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply))
        }
        for neighbor in ["AGENTS.md ", "Sources/AGENTS.md\n"] {
            let reply = ReadReplySelectionPolicy.Metadata(totalLines: 3, firstLine: 1, lastLine: 3, displayPath: neighbor)
            let selection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: reply))
            guard case let .full(path) = selection else { return XCTFail("Expected ordinary filename neighbor to remain eligible") }
            XCTAssertEqual(Data(path.utf8), Data(neighbor.utf8))
        }
    }

    func testReadReplyFallbackUsesEmptyOnlyPolicyAndRejectsMalformedChosenSelector() throws {
        func reply(_ display: String?, totalLines: Int = 3, first: Int = 1, last: Int = 3) -> ReadReplySelectionPolicy.Metadata {
            .init(totalLines: totalLines, firstLine: first, lastLine: last, displayPath: display)
        }
        let fallback = " Sources/fallback.swift "
        for missing in [String?.none, ""] {
            let selection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: reply(missing), fallbackPath: fallback))
            guard case let .full(path) = selection else { return XCTFail("Expected exact fallback selector") }
            XCTAssertEqual(Data(path.utf8), Data(fallback.utf8))
        }
        let literalWhitespace = " \t"
        let whitespaceSelection = try XCTUnwrap(ReadReplySelectionPolicy.selection(from: reply(literalWhitespace), fallbackPath: fallback))
        guard case let .full(path) = whitespaceSelection else { return XCTFail("Whitespace-only filename became fallback decoration") }
        XCTAssertEqual(Data(path.utf8), Data(literalWhitespace.utf8))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(nil)))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(""), fallbackPath: ""))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply("bad\0name"), fallbackPath: fallback))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(nil), fallbackPath: "bad\0fallback"))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(fallback, totalLines: 0)))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(fallback, first: 0)))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(fallback, first: 4)))
        XCTAssertNil(ReadReplySelectionPolicy.selection(from: reply(fallback, first: 2, last: 1)))
    }
}
