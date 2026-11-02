#if os(Linux)
    import Foundation
    import Glibc
    import RepoPromptVCS
    import XCTest

    final class LinuxWorktreeFileClonerTests: XCTestCase {
        func testCopyFallbackPreservesContentsAndExecutableModeWithoutOverwriting() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
            let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes = Data((0 ..< 131_123).map { UInt8($0 % 251) })
            let sourceFile = sourceDirectory.appendingPathComponent("fixture")
            try bytes.write(to: sourceFile)
            XCTAssertEqual(chmod(sourceFile.path, 0o755), 0)
            let source = open(sourceDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            let destination = open(destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(source, 0)
            XCTAssertGreaterThanOrEqual(destination, 0)
            guard source >= 0, destination >= 0 else { return }
            defer {
                close(source)
                close(destination)
            }
            let outcome = GitWorktreeFileCloner.cloneRegularFile(
                sourceDirectory: source, name: "fixture", destinationDirectory: destination,
                metadata: .preserveSource, allowCopyFallback: true,
                clone: { _, _, _, _ in ENOTSUP }
            )
            XCTAssertEqual(outcome, .copied)
            let target = destinationDirectory.appendingPathComponent("fixture")
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            var status = stat()
            XCTAssertEqual(stat(target.path, &status), 0)
            XCTAssertEqual(status.st_mode & 0o777, 0o755)
            XCTAssertEqual(GitWorktreeFileCloner.cloneRegularFile(
                sourceDirectory: source, name: "fixture", destinationDirectory: destination,
                metadata: .preserveSource, allowCopyFallback: true
            ), .destinationExists)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }
#endif
