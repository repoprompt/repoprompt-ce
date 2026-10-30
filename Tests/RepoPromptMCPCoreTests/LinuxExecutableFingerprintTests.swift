#if os(Linux)
    import Foundation
    import Glibc
    @testable import RepoPromptMCPCore
    import XCTest

    final class LinuxExecutableFingerprintTests: XCTestCase {
        func testDeletedExecutableCannotBeReplacedByADeletedSuffixDecoy() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("fixture")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["30"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            XCTAssertNotNil(DirectHeadlessMCPService.verifiedExecutableFingerprint(processID: process.processIdentifier))
            try FileManager.default.removeItem(at: executable)
            try Data("decoy".utf8).write(to: directory.appendingPathComponent("fixture (deleted)"))
            XCTAssertNil(DirectHeadlessMCPService.verifiedExecutableFingerprint(processID: process.processIdentifier))
        }
    }
#endif
