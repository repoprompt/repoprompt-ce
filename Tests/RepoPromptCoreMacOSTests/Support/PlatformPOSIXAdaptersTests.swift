import Darwin
@testable import RepoPromptCoreMacOS
import XCTest

final class PlatformPOSIXAdaptersTests: XCTestCase {
    func testDescriptorPolicyMapsInvalidDescriptorAndNegativeShutdownIsSafe() {
        XCTAssertThrowsError(try PlatformDescriptorPolicy.setCloseOnExec(-1)) { error in
            XCTAssertEqual(
                error as? PlatformDescriptorConfigurationError,
                .invalidFileDescriptor(fd: -1)
            )
        }
        PlatformDescriptorPolicy.shutdownSocketReadWrite(-1)
    }

    func testFDWriterPreservesBytesAndMapsBadDescriptor() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let payload = Data("platform-writer".utf8)
        try PlatformFDWriter.writeAll(payload, to: descriptors[1])
        var bytes = [UInt8](repeating: 0, count: payload.count)
        XCTAssertEqual(read(descriptors[0], &bytes, bytes.count), payload.count)
        XCTAssertEqual(Data(bytes), payload)

        XCTAssertThrowsError(try PlatformFDWriter.writeAll(payload, to: -1)) { error in
            XCTAssertEqual(error as? PlatformFDWriteError, .badDescriptor(errno: EBADF))
        }
    }
}
