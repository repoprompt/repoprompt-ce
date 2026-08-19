import Dispatch
import Foundation
@testable import RepoPromptApp
import XCTest

final class FileHandleChunkChannelTests: XCTestCase {
    func testReadAndYieldKeepsAnInFlightCallbackAheadOfTheFinalDrain() async {
        let channel = FileHandleChunkChannel()
        let callbackReadStarted = DispatchSemaphore(value: 0)
        let releaseCallbackRead = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let drainAttemptStarted = DispatchSemaphore(value: 0)
        let drainFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = channel.readAndYield {
                callbackReadStarted.signal()
                _ = releaseCallbackRead.wait(timeout: .now() + 5)
                return Data("callback".utf8)
            }
            callbackFinished.signal()
        }

        XCTAssertEqual(callbackReadStarted.wait(timeout: .now() + 5), .success)

        DispatchQueue.global().async {
            drainAttemptStarted.signal()
            _ = channel.readAndYield {
                Data("drain".utf8)
            }
            drainFinished.signal()
        }

        XCTAssertEqual(drainAttemptStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(
            drainFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "The final drain must wait for the in-flight readability callback"
        )

        releaseCallbackRead.signal()
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(drainFinished.wait(timeout: .now() + 5), .success)

        channel.finish()
        var chunks: [Data] = []
        for await chunk in channel.stream {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, [Data("callback".utf8), Data("drain".utf8)])
    }
}
