import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessNewlineFrameDecoderTests: XCTestCase {
    func testSplitFramesMultipleFramesCRLFAndEmptyLines() {
        var decoder = HeadlessNewlineFrameDecoder(maximumFrameBytes: 32)

        XCTAssertEqual(decoder.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(
            decoder.append(Data("1}\n\n{\"b\":2}\r\n".utf8)),
            [
                .frame(Data("{\"a\":1}".utf8)),
                .frame(Data("{\"b\":2}".utf8))
            ]
        )
    }

    func testExactOneMiBBoundaryIsAccepted() throws {
        var decoder = HeadlessNewlineFrameDecoder()
        let payload = Data(repeating: 0x61, count: HeadlessNewlineFrameDecoder.defaultMaximumFrameBytes)
        var chunk = payload
        chunk.append(0x0A)

        let events = decoder.append(chunk)
        XCTAssertEqual(events.count, 1)
        guard case let .frame(frame) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected an accepted boundary frame")
        }
        XCTAssertEqual(frame.count, payload.count)
    }

    func testOneMiBPlusOneIsRejectedAtTheDefaultLimit() {
        var decoder = HeadlessNewlineFrameDecoder()
        var chunk = Data(
            repeating: 0x61,
            count: HeadlessNewlineFrameDecoder.defaultMaximumFrameBytes + 1
        )
        chunk.append(0x0A)

        XCTAssertEqual(
            decoder.append(chunk),
            [
                .parseError(
                    message: "JSON-RPC frame exceeds headless maximum of 1048576 bytes."
                )
            ]
        )
    }

    func testTerminalCRCountsTowardLimitBeforeNormalization() {
        var accepted = HeadlessNewlineFrameDecoder(maximumFrameBytes: 4)
        XCTAssertEqual(
            accepted.append(Data("abc\r\n".utf8)),
            [.frame(Data("abc".utf8))]
        )

        var rejected = HeadlessNewlineFrameDecoder(maximumFrameBytes: 4)
        let events = rejected.append(Data("abcd\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(parseErrors(events).count, 1)
    }

    func testAggregateChunkOverOneMiBAcceptsIndividuallyValidFrames() {
        var decoder = HeadlessNewlineFrameDecoder()
        let frameSize = 600_000
        var chunk = Data(repeating: 0x61, count: frameSize)
        chunk.append(0x0A)
        chunk.append(Data(repeating: 0x62, count: frameSize))
        chunk.append(0x0A)
        XCTAssertGreaterThan(chunk.count, HeadlessNewlineFrameDecoder.defaultMaximumFrameBytes)

        let events = decoder.append(chunk)
        XCTAssertEqual(frames(events).map(\.count), [frameSize, frameSize])
        XCTAssertTrue(parseErrors(events).isEmpty)
    }

    func testOversizedFrameIsDiscardedAndLaterFrameInSameChunkIsDecoded() {
        var decoder = HeadlessNewlineFrameDecoder(maximumFrameBytes: 4)

        let events = decoder.append(Data("abcde ignored\n{}\n".utf8))
        XCTAssertEqual(
            events,
            [
                .parseError(message: "JSON-RPC frame exceeds headless maximum of 4 bytes."),
                .frame(Data("{}".utf8))
            ]
        )
    }

    func testOversizedFrameSpanningChunksReportsOnceAndResumesAfterNewline() {
        var decoder = HeadlessNewlineFrameDecoder(maximumFrameBytes: 4)

        XCTAssertEqual(parseErrors(decoder.append(Data("abcde".utf8))).count, 1)
        XCTAssertEqual(decoder.append(Data("still discarded".utf8)), [])
        let recovered = decoder.append(Data("\n[]\n".utf8))
        XCTAssertEqual(parseErrors(recovered).count, 0)
        XCTAssertEqual(frames(recovered), [Data("[]".utf8)])
    }

    func testFinishNeverEmitsResidualFrameAndRejectsNonWhitespaceResidual() {
        var decoder = HeadlessNewlineFrameDecoder(maximumFrameBytes: 32)
        XCTAssertEqual(decoder.append(Data("{\"valid\":true}".utf8)), [])

        let events = decoder.finish()
        XCTAssertTrue(frames(events).isEmpty)
        XCTAssertEqual(parseErrors(events), ["Incomplete newline-delimited JSON-RPC frame at EOF."])
    }

    func testFinishIgnoresWhitespaceAndDoesNotDuplicateOversizeError() {
        var whitespace = HeadlessNewlineFrameDecoder(maximumFrameBytes: 8)
        XCTAssertEqual(whitespace.append(Data([0x20, 0x09, 0x0D])), [])
        XCTAssertEqual(whitespace.finish(), [])

        var oversized = HeadlessNewlineFrameDecoder(maximumFrameBytes: 4)
        XCTAssertEqual(parseErrors(oversized.append(Data("abcde".utf8))).count, 1)
        XCTAssertEqual(oversized.finish(), [])
    }

    func testDecoderCanBeReusedAfterFinish() {
        var decoder = HeadlessNewlineFrameDecoder(maximumFrameBytes: 8)
        XCTAssertEqual(parseErrors(decoder.append(Data("garbage".utf8))).count, 0)
        XCTAssertEqual(parseErrors(decoder.finish()).count, 1)
        XCTAssertEqual(decoder.append(Data("{}\n".utf8)), [.frame(Data("{}".utf8))])
    }

    private func frames(_ events: [HeadlessNewlineFrameDecoder.Event]) -> [Data] {
        events.compactMap { event in
            guard case let .frame(data) = event else { return nil }
            return data
        }
    }

    private func parseErrors(_ events: [HeadlessNewlineFrameDecoder.Event]) -> [String] {
        events.compactMap { event in
            guard case let .parseError(message) = event else { return nil }
            return message
        }
    }
}
