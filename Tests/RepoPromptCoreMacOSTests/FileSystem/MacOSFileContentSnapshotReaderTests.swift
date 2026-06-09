import Darwin
import Foundation
@testable import RepoPromptCore
@testable import RepoPromptCoreMacOS
import XCTest

final class MacOSFileContentSnapshotReaderTests: XCTestCase {
    func testOpenedDescriptorRetainsStableIdentityAfterPathReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSFileContentSnapshotReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("content.txt")
        try Data("first".utf8).write(to: file)

        let reader = MacOSFileContentSnapshotReader()
        let initialPathFingerprint = try reader.fingerprint(atPath: file.path)
        let handle = try reader.openReadOnlyFileHandle(atPath: file.path)
        defer { try? handle.close() }

        XCTAssertEqual(try reader.fingerprint(fileDescriptor: handle.fileDescriptor), initialPathFingerprint)
        XCTAssertNotEqual(Darwin.fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)

        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)

        let retainedDescriptorFingerprint = try reader.fingerprint(fileDescriptor: handle.fileDescriptor)
        XCTAssertEqual(retainedDescriptorFingerprint.deviceID, initialPathFingerprint.deviceID)
        XCTAssertEqual(retainedDescriptorFingerprint.fileNumber, initialPathFingerprint.fileNumber)
        XCTAssertEqual(retainedDescriptorFingerprint.byteSize, initialPathFingerprint.byteSize)
        XCTAssertEqual(retainedDescriptorFingerprint.modificationSeconds, initialPathFingerprint.modificationSeconds)
        XCTAssertEqual(retainedDescriptorFingerprint.modificationNanoseconds, initialPathFingerprint.modificationNanoseconds)
        XCTAssertNotEqual(try reader.fingerprint(atPath: file.path), initialPathFingerprint)
    }

    func testRejectsSymbolicLinkWithoutFollowingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSFileContentSnapshotReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let reader = MacOSFileContentSnapshotReader()
        assertInvalidRelativePath { try reader.fingerprint(atPath: link.path) }
        assertInvalidRelativePath { try reader.openReadOnlyFileHandle(atPath: link.path) }
    }

    private func assertInvalidRelativePath(
        _ operation: () throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let fileSystemError = error as? FileSystemError,
                  case .invalidRelativePath = fileSystemError
            else {
                return XCTFail("Expected invalidRelativePath, got \(error)", file: file, line: line)
            }
        }
    }
}
