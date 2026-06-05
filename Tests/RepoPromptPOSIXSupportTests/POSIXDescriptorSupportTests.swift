import Darwin
import RepoPromptPOSIXSupport
import XCTest

final class POSIXDescriptorSupportTests: XCTestCase {
    func testSetCloseOnExecPreservesOtherDescriptorFlags() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        defer {
            if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }

        let before = fcntl(descriptors[0], F_GETFD)
        XCTAssertGreaterThanOrEqual(before, 0)

        try POSIXDescriptorSupport.setCloseOnExec(descriptors[0])

        let after = fcntl(descriptors[0], F_GETFD)
        XCTAssertNotEqual(after & FD_CLOEXEC, 0)
        XCTAssertEqual(after & ~FD_CLOEXEC, before & ~FD_CLOEXEC)
    }

    func testInvalidDescriptorReturnsTypedError() {
        XCTAssertThrowsError(try POSIXDescriptorSupport.setCloseOnExec(-1)) { error in
            XCTAssertEqual(error as? POSIXDescriptorConfigurationError, .invalidFileDescriptor(fd: -1))
        }
    }

    func testShutdownIgnoresNegativeDescriptor() {
        POSIXDescriptorSupport.shutdownSocketReadWrite(-1)
    }
}
