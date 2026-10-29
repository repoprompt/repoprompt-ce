#if os(Linux)
    import Foundation
    import Glibc
    import RepoPromptProcess
    import XCTest

    final class LinuxProcessPortabilityTests: XCTestCase {
        func testSpawnUsesRequestedDirectoryAndDoesNotInheritUnrelatedDescriptors() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let descriptor = open("/dev/null", O_RDONLY)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let inheritedCandidate = fcntl(descriptor, F_DUPFD, 100)
            XCTAssertGreaterThanOrEqual(inheritedCandidate, 100)
            guard inheritedCandidate >= 100 else { return }
            defer { close(inheritedCandidate) }

            let child = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", "pwd; test ! -e /proc/self/fd/\(inheritedCandidate)"],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: directory.path,
                purpose: .tool
            )
            try child.stdin?.close()
            defer {
                try? child.stdout.close()
                try? child.stderr.close()
            }
            let observer = ChildProcessExitObserver.observe(pid: child.pid)
            let output = try child.stdout.readToEnd() ?? Data()
            let outcome = await observer.wait(timeout: 5)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), directory.path + "\n")
            if case let .exited(status)? = outcome {
                XCTAssertEqual(status, .exited(code: 0))
            } else {
                XCTFail("Spawned process did not exit successfully: \(String(describing: outcome))")
            }
        }
    }
#endif
