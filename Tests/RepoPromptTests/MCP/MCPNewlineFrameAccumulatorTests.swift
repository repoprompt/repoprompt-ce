import Foundation
@testable import RepoPromptShared
import XCTest

final class MCPNewlineFrameAccumulatorTests: XCTestCase {
    func testBoundaryFramesPreserveOrderAndIndependentOwnership() throws {
        var accumulator = MCPNewlineFrameAccumulator(
            maximumFrameByteCount: 4,
            bufferReservation: 0,
            compactionThreshold: 64
        )
        accumulator.append(Data("abc\n1234\n".utf8))

        let justUnder = try XCTUnwrap(accumulator.nextFrame())
        let atLimit = try XCTUnwrap(accumulator.nextFrame())
        XCTAssertEqual(justUnder, Data("abc".utf8))
        XCTAssertEqual(atLimit, Data("1234".utf8))
        XCTAssertNil(try accumulator.nextFrame())

        accumulator.append(Data("next\n".utf8))
        XCTAssertEqual(try accumulator.nextFrame(), Data("next".utf8))
        accumulator.reset(keepingCapacity: false)

        XCTAssertEqual(justUnder, Data("abc".utf8))
        XCTAssertEqual(atLimit, Data("1234".utf8))
    }

    func testDelimiterAfterCapFailsWithDistinctError() throws {
        var accumulator = MCPNewlineFrameAccumulator(maximumFrameByteCount: 4)
        accumulator.append(Data("1234".utf8))
        XCTAssertNil(try accumulator.nextFrame())

        accumulator.append(Data("5\n".utf8))
        XCTAssertThrowsError(try accumulator.nextFrame()) { error in
            XCTAssertEqual(
                error as? MCPNewlineFrameTooLargeError,
                MCPNewlineFrameTooLargeError(maximumByteCount: 4, accumulatedByteCount: 5)
            )
        }
    }

    func testOverCapWithoutDelimiterFailsClosed() {
        var accumulator = MCPNewlineFrameAccumulator(maximumFrameByteCount: 4)
        accumulator.append(Data("12345".utf8))

        XCTAssertThrowsError(try accumulator.nextFrame()) { error in
            XCTAssertEqual(
                error as? MCPNewlineFrameTooLargeError,
                MCPNewlineFrameTooLargeError(maximumByteCount: 4, accumulatedByteCount: 5)
            )
        }
    }

    func testCursorCompactsConsumedPrefixAndPreservesResidual() throws {
        var accumulator = MCPNewlineFrameAccumulator(
            maximumFrameByteCount: 16,
            bufferReservation: 0,
            compactionThreshold: 4
        )
        accumulator.append(Data("a\nbb\nx".utf8))

        XCTAssertEqual(try accumulator.nextFrame(), Data("a".utf8))
        XCTAssertEqual(accumulator.consumedPrefixByteCount, 2)
        XCTAssertEqual(accumulator.storageByteCount, 6)

        XCTAssertEqual(try accumulator.nextFrame(), Data("bb".utf8))
        XCTAssertEqual(accumulator.consumedPrefixByteCount, 0)
        XCTAssertEqual(accumulator.storageByteCount, 1)
        XCTAssertEqual(accumulator.residualByteCount, 1)
        XCTAssertTrue(accumulator.hasResidualData)

        accumulator.append(UInt8(ascii: "\n"))
        XCTAssertEqual(try accumulator.nextFrame(), Data("x".utf8))
        XCTAssertFalse(accumulator.hasResidualData)
    }

    func testResetKeepingCapacityDiscardsLogicalBytesAndCursorState() throws {
        var accumulator = MCPNewlineFrameAccumulator(
            maximumFrameByteCount: 16,
            bufferReservation: 32,
            compactionThreshold: 64
        )
        accumulator.append(Data("old\nresidual".utf8))
        XCTAssertEqual(try accumulator.nextFrame(), Data("old".utf8))
        XCTAssertTrue(accumulator.hasResidualData)

        accumulator.reset(keepingCapacity: true)

        XCTAssertEqual(accumulator.storageByteCount, 0)
        XCTAssertEqual(accumulator.consumedPrefixByteCount, 0)
        XCTAssertFalse(accumulator.hasResidualData)
        accumulator.append(Data("new\n".utf8))
        XCTAssertEqual(try accumulator.nextFrame(), Data("new".utf8))
        XCTAssertNil(try accumulator.nextFrame())
    }

    func testEmptyFramesRemainObservableToIngressPolicy() throws {
        var accumulator = MCPNewlineFrameAccumulator(maximumFrameByteCount: 1)
        accumulator.append(Data("\n\n".utf8))

        XCTAssertEqual(try accumulator.nextFrame(), Data())
        XCTAssertEqual(try accumulator.nextFrame(), Data())
        XCTAssertNil(try accumulator.nextFrame())
    }
}
