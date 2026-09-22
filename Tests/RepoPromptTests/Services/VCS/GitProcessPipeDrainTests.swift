import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class GitProcessPipeDrainTests: XCTestCase {
    func testReadabilityCallbackAfterFinishCannotConsumeOrAppendData() async {
        let (stream, drain) = GitProcessPipeDrain.makeStream()
        let tailData = Data("tail".utf8)
        var didReadAfterFinish = false

        drain.finish { tailData }
        drain.consume {
            didReadAfterFinish = true
            return Data("late".utf8)
        }

        XCTAssertFalse(didReadAfterFinish)
        let output = await Self.collect(stream)
        XCTAssertEqual(output, tailData)
    }

    func testByteLimitRetainsExactBoundaryAndFlagsFirstExcessByte() async throws {
        for (payload, expected, didExceed) in [
            (Data("four".utf8), Data("four".utf8), false),
            (Data("five!".utf8), Data("five".utf8), true)
        ] {
            let pipe = Pipe()
            let (stream, drain) = try GitProcessPipeDrain.makeStream(
                readingFrom: pipe.fileHandleForReading,
                byteLimit: 4
            )
            let collected = Task { await Self.collect(stream) }
            pipe.fileHandleForWriting.write(payload)
            pipe.fileHandleForWriting.closeFile()
            while !drain.consumeAvailableData() {}

            let output = await collected.value
            XCTAssertEqual(output, expected)
            XCTAssertEqual(drain.didExceedByteLimit, didExceed)
        }
    }

    func testCancelClosesOwnedDuplicateWithoutClosingOriginalDescriptor() throws {
        let pipe = Pipe()
        let originalDescriptor = pipe.fileHandleForReading.fileDescriptor
        let (_, drain) = try GitProcessPipeDrain.makeStream(readingFrom: pipe.fileHandleForReading)
        let ownedDescriptor = try XCTUnwrap(drain.ownedDescriptorForTesting)
        XCTAssertNotEqual(ownedDescriptor, originalDescriptor)
        XCTAssertGreaterThanOrEqual(fcntl(ownedDescriptor, F_GETFD), 0)

        drain.cancel()

        errno = 0
        XCTAssertEqual(fcntl(ownedDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertGreaterThanOrEqual(fcntl(originalDescriptor, F_GETFD), 0)
        pipe.fileHandleForWriting.closeFile()
    }

    private static func collect(_ stream: AsyncStream<Data>) async -> Data {
        var result = Data()
        for await chunk in stream {
            result.append(chunk)
        }
        return result
    }
}
