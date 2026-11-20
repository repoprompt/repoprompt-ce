import Foundation
import RepoPromptShared
import XCTest

final class MCPNewlineFrameBufferTests: XCTestCase {
    func testEveryChunkBoundaryPreservesFramesEmptyLinesAndPartialEOF() {
        let bytes = Data("α\n\nbeta\ntail".utf8)
        let expected = [Data("α".utf8), Data(), Data("beta".utf8)]
        for split in 0 ... bytes.count {
            var buffer = MCPNewlineFrameBuffer()
            var frames: [Data] = []
            buffer.append(contentsOf: bytes.prefix(split))
            while let frame = buffer.nextFrame() {
                frames.append(frame)
            }
            buffer.append(contentsOf: bytes.dropFirst(split))
            while let frame = buffer.nextFrame() {
                frames.append(frame)
            }
            XCTAssertEqual(frames, expected, "split=\(split)")
            XCTAssertEqual(buffer.count, 4)
            XCTAssertFalse(buffer.isEmpty)
            XCTAssertNil(buffer.nextFrame())
            #if DEBUG
                XCTAssertEqual(buffer.inspectedByteCount, bytes.count, "Every byte is searched once, split=\(split)")
            #endif
        }
    }

    func testFragmentedLargeFrameNeverRescansItsIncompletePrefix() {
        var buffer = MCPNewlineFrameBuffer()
        let chunk = [UInt8](repeating: 0x78, count: 4096)
        for _ in 0 ..< 64 {
            buffer.append(contentsOf: chunk)
            XCTAssertNil(buffer.nextFrame())
            XCTAssertNil(buffer.nextFrame(), "A pump pass without new bytes must not rescan")
            #if DEBUG
                XCTAssertEqual(buffer.inspectedByteCount, buffer.count)
            #endif
        }
        buffer.append(contentsOf: [0x0A])
        XCTAssertEqual(buffer.nextFrame(), Data(repeating: 0x78, count: 64 * chunk.count))
        XCTAssertTrue(buffer.isEmpty)
        #if DEBUG
            XCTAssertEqual(buffer.inspectedByteCount, 64 * chunk.count + 1)
        #endif
    }

    func testResetAndCustomDelimiterPreserveTheNextIncarnation() {
        var buffer = MCPNewlineFrameBuffer(delimiter: 0, capacity: 32)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertNil(buffer.nextFrame())
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: [0, 4, 5, 0, 6])
        XCTAssertEqual(buffer.nextFrame(), Data())
        XCTAssertEqual(buffer.nextFrame(), Data([4, 5]))
        XCTAssertNil(buffer.nextFrame())
        XCTAssertEqual(buffer.count, 1)
        #if DEBUG
            XCTAssertEqual(buffer.inspectedByteCount, 5)
        #endif
    }
}
