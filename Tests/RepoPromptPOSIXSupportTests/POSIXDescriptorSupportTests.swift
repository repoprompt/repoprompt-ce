import Darwin
import Foundation
import RepoPromptPOSIXSupport
import XCTest

final class POSIXDescriptorSupportTests: XCTestCase {
    func testPathReturnsOpenedFilePath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptPOSIXSupportTests-\(UUID().uuidString)")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        let descriptorPath = try POSIXDescriptorSupport.path(for: descriptor)
        XCTAssertEqual(
            URL(fileURLWithPath: descriptorPath).resolvingSymlinksInPath().standardizedFileURL.path,
            file.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func testPathForInvalidDescriptorReturnsTypedError() {
        XCTAssertThrowsError(try POSIXDescriptorSupport.path(for: -1)) { error in
            XCTAssertEqual(error as? POSIXDescriptorPathError, .invalidFileDescriptor(fd: -1))
        }
    }

    func testPathLookupFailureReturnsTypedErrno() throws {
        let descriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(Darwin.close(descriptor), 0)

        XCTAssertThrowsError(try POSIXDescriptorSupport.path(for: descriptor)) { error in
            XCTAssertEqual(error as? POSIXDescriptorPathError, .getPathFailed(fd: descriptor, errno: EBADF))
        }
    }

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
