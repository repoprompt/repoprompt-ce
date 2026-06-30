import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class GitServiceCancellationTests: XCTestCase {
        func testCancellationDrainsTerminatedChildBeforeReleasingAdmission() async throws {
            let fixture = try GitCancellationFixture()
            defer { fixture.cleanup() }
            let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
            let baseline = await admission.snapshot()
            let git = GitService(
                gitExecutableURL: fixture.executableURL,
                processAdmissionController: admission
            )

            MCPToolWorkCountDiagnostics.resetForTesting()
            let command = Task {
                try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: "cancel_drain") {
                    try await git.findGitRoot(from: fixture.repo)
                }
            }
            defer { command.cancel() }

            let childPID = try await fixture.awaitReadyPID()
            defer {
                if kill(childPID, 0) == 0 {
                    _ = kill(childPID, SIGKILL)
                }
            }

            let completion = TestCompletionSignal()
            Task {
                _ = await command.result
                completion.signal()
            }

            command.cancel()
            try await fixture.awaitOutputGate()
            let heldAdmission = await admission.snapshot()
            XCTAssertEqual(heldAdmission.activeGlobal, baseline.activeGlobal + 1)
            XCTAssertEqual(heldAdmission.activeLeaseCount, baseline.activeLeaseCount + 1)
            XCTAssertEqual(heldAdmission.waiterCount, baseline.waiterCount)
            XCTAssertEqual(heldAdmission.activeByRepository.values.sorted(), [1])
            let completedWhileGated = await completion.wait(timeout: .zero)
            XCTAssertFalse(completedWhileGated, "Cancelled Git command completed before the gated child exited.")

            try fixture.releaseChild()
            let completed = await completion.wait(timeout: .seconds(15))
            if !completed {
                _ = kill(childPID, SIGKILL)
                _ = await completion.wait(timeout: .seconds(5))
                XCTFail("Cancelled Git command did not finish while the child flushed output after SIGTERM.")
                return
            }

            switch await command.result {
            case .success:
                XCTFail("Cancelled Git command returned success instead of CancellationError.")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)")
            }

            let snapshot = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().git.last)
            XCTAssertEqual(snapshot.commandCount, 1)
            XCTAssertEqual(snapshot.outputBytes, fixture.expectedOutputByteCount)
            let finalAdmission = await admission.snapshot()
            XCTAssertEqual(finalAdmission, baseline)

            errno = 0
            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH, "Git subprocess was not reaped after cancellation.")
        }

        func testCancellationEscalatesWhenTerminatedChildDoesNotExit() async throws {
            let fixture = try GitCancellationFixture()
            defer { fixture.cleanup() }
            let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
            let baseline = await admission.snapshot()
            let git = GitService(
                gitExecutableURL: fixture.executableURL,
                processAdmissionController: admission,
                processTerminationGrace: .seconds(2)
            )

            let command = Task {
                try await git.findGitRoot(from: fixture.repo)
            }
            defer { command.cancel() }

            let childPID = try await fixture.awaitReadyPID()
            defer {
                if kill(childPID, 0) == 0 {
                    _ = kill(childPID, SIGKILL)
                }
            }

            let completion = TestCompletionSignal()
            Task {
                _ = await command.result
                completion.signal()
            }

            command.cancel()
            try await fixture.awaitOutputGate()
            let completed = await completion.wait(timeout: .seconds(5))
            if !completed {
                _ = kill(childPID, SIGKILL)
                _ = await completion.wait(timeout: .seconds(5))
                XCTFail("Cancelled Git command did not complete after the SIGKILL grace period.")
                return
            }

            switch await command.result {
            case .success:
                XCTFail("Cancelled Git command returned success instead of escalating to SIGKILL.")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "Unexpected escalation result: \(error)")
            }

            let finalAdmission = await admission.snapshot()
            XCTAssertEqual(finalAdmission, baseline)
            errno = 0
            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH, "Escalated Git subprocess was not reaped.")
        }

        func testCapabilityBoundBlobCancellationDrainsBeforeReleasingAdmission() async throws {
            let fixture = try GitCancellationFixture()
            defer { fixture.cleanup() }
            let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
            let baseline = await admission.snapshot()
            let git = GitService(
                gitExecutableURL: fixture.executableURL,
                processAdmissionController: admission
            )
            let oid = GitBlobOID.blob(bytes: Data(), objectFormat: .sha1)
            let command = Task {
                try await git.gitBlobObjectBytes(
                    in: fixture.layout,
                    oid: oid,
                    expectedByteCount: GitCancellationFixture.payloadByteCount
                )
            }
            defer { command.cancel() }

            let childPID = try await fixture.awaitReadyPID()
            defer {
                if kill(childPID, 0) == 0 {
                    _ = kill(childPID, SIGKILL)
                }
            }
            let completion = TestCompletionSignal()
            Task {
                _ = await command.result
                completion.signal()
            }

            command.cancel()
            try await fixture.awaitOutputGate()
            let heldAdmission = await admission.snapshot()
            XCTAssertEqual(heldAdmission.activeGlobal, baseline.activeGlobal + 1)
            XCTAssertEqual(heldAdmission.activeLeaseCount, baseline.activeLeaseCount + 1)
            let completedWhileGated = await completion.wait(timeout: .zero)
            XCTAssertFalse(completedWhileGated)

            try fixture.releaseChild()
            let completed = await completion.wait(timeout: .seconds(15))
            if !completed {
                _ = kill(childPID, SIGKILL)
                _ = await completion.wait(timeout: .seconds(5))
                XCTFail("Cancelled capability-bound blob read did not complete after release.")
                return
            }
            switch await command.result {
            case .success:
                XCTFail("Cancelled capability-bound blob read returned bytes.")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)")
            }
            let finalAdmission = await admission.snapshot()
            XCTAssertEqual(finalAdmission, baseline)
            errno = 0
            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH, "Capability-bound blob subprocess was not reaped.")
        }

        func testCapabilityBoundBlobCancellationEscalatesAndReleasesAdmission() async throws {
            let fixture = try GitCancellationFixture()
            defer { fixture.cleanup() }
            let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
            let baseline = await admission.snapshot()
            let git = GitService(
                gitExecutableURL: fixture.executableURL,
                processAdmissionController: admission,
                processTerminationGrace: .milliseconds(250)
            )
            let oid = GitBlobOID.blob(bytes: Data(), objectFormat: .sha1)
            let command = Task {
                try await git.gitBlobObjectBytes(
                    in: fixture.layout,
                    oid: oid,
                    expectedByteCount: GitCancellationFixture.payloadByteCount
                )
            }
            defer { command.cancel() }

            let childPID = try await fixture.awaitReadyPID()
            defer {
                if kill(childPID, 0) == 0 {
                    _ = kill(childPID, SIGKILL)
                }
            }
            let completion = TestCompletionSignal()
            Task {
                _ = await command.result
                completion.signal()
            }

            command.cancel()
            try await fixture.awaitOutputGate()
            let completed = await completion.wait(timeout: .seconds(5))
            if !completed {
                _ = kill(childPID, SIGKILL)
                _ = await completion.wait(timeout: .seconds(5))
                XCTFail("Capability-bound blob read did not complete after SIGKILL escalation.")
                return
            }
            switch await command.result {
            case .success:
                XCTFail("TERM-resistant capability-bound blob read returned bytes.")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "Unexpected escalation result: \(error)")
            }
            let finalAdmission = await admission.snapshot()
            XCTAssertEqual(finalAdmission, baseline)
            errno = 0
            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH, "SIGKILL-escalated blob subprocess was not reaped.")
        }
    }

    private final class GitCancellationFixture {
        static let payloadByteCount = 4 * 1024 * 1024

        let sandbox: URL
        let repo: URL
        let executableURL: URL
        let expectedOutputByteCount: Int

        var layout: GitRepositoryLayout {
            let gitDirectory = repo.appendingPathComponent(".git", isDirectory: true)
            return GitRepositoryLayout(
                workTreeRoot: repo,
                dotGitPath: gitDirectory,
                gitDir: gitDirectory,
                commonDir: gitDirectory,
                isWorktree: false
            )
        }

        private let readyDescriptor: Int32
        private let outputGateDescriptor: Int32
        private let releaseDescriptor: Int32

        init() throws {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitServiceCancellationTests-\(UUID().uuidString)", isDirectory: true)
            let repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
            let executableURL = sandbox.appendingPathComponent("git-stub")
            let readyURL = sandbox.appendingPathComponent("ready.fifo")
            let outputGateURL = sandbox.appendingPathComponent("output-gate.fifo")
            let releaseURL = sandbox.appendingPathComponent("release.fifo")
            var shouldRemoveSandbox = true
            defer {
                if shouldRemoveSandbox {
                    try? FileManager.default.removeItem(at: sandbox)
                }
            }

            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(".git/objects", isDirectory: true),
                withIntermediateDirectories: true
            )
            let pwd = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/pwd"),
                currentDirectoryURL: repo
            )
            guard pwd.terminationStatus == 0 else {
                throw NSError(
                    domain: "GitServiceCancellationTests.pwd",
                    code: Int(pwd.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: pwd.outputText]
                )
            }
            let expectedRoot = URL(
                fileURLWithPath: pwd.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let expectedOutputByteCount = Self.payloadByteCount + expectedRoot.path.utf8.count + 1
            guard mkfifo(readyURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard mkfifo(outputGateURL.path, S_IRUSR | S_IWUSR) == 0,
                  mkfifo(releaseURL.path, S_IRUSR | S_IWUSR) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let readyDescriptor = Darwin.open(readyURL.path, O_RDWR | O_CLOEXEC)
            let outputGateDescriptor = Darwin.open(outputGateURL.path, O_RDWR | O_CLOEXEC)
            let releaseDescriptor = Darwin.open(releaseURL.path, O_RDWR | O_CLOEXEC)
            var shouldCloseDescriptors = true
            defer {
                if shouldCloseDescriptors {
                    if readyDescriptor >= 0 {
                        _ = Darwin.close(readyDescriptor)
                    }
                    if outputGateDescriptor >= 0 {
                        _ = Darwin.close(outputGateDescriptor)
                    }
                    if releaseDescriptor >= 0 {
                        _ = Darwin.close(releaseDescriptor)
                    }
                }
            }
            guard readyDescriptor >= 0,
                  outputGateDescriptor >= 0,
                  releaseDescriptor >= 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let sourceURL = sandbox.appendingPathComponent("git-stub.c")
            let readyPathLiteral = try Self.cStringLiteral(readyURL.path)
            let outputGatePathLiteral = try Self.cStringLiteral(outputGateURL.path)
            let releasePathLiteral = try Self.cStringLiteral(releaseURL.path)
            let source = """
            #include <errno.h>
            #include <fcntl.h>
            #include <signal.h>
            #include <stdio.h>
            #include <string.h>
            #include <unistd.h>

            static int write_all(int fd, const void *buffer, size_t count) {
                const unsigned char *cursor = buffer;
                while (count > 0) {
                    ssize_t written = write(fd, cursor, count);
                    if (written > 0) {
                        cursor += written;
                        count -= (size_t)written;
                        continue;
                    }
                    if (written < 0 && errno == EINTR) {
                        continue;
                    }
                    return -1;
                }
                return 0;
            }

            int main(void) {
                sigset_t termination_set;
                sigemptyset(&termination_set);
                sigaddset(&termination_set, SIGTERM);
                if (sigprocmask(SIG_BLOCK, &termination_set, NULL) != 0) {
                    return 2;
                }

                int ready_fd = open(\(readyPathLiteral), O_WRONLY);
                if (ready_fd < 0) {
                    return 3;
                }
                char ready[64];
                int ready_count = snprintf(ready, sizeof(ready), "%d\\n", getpid());
                if (ready_count <= 0 || write_all(ready_fd, ready, (size_t)ready_count) != 0) {
                    return 4;
                }
                close(ready_fd);

                int received_signal = 0;
                if (sigwait(&termination_set, &received_signal) != 0 || received_signal != SIGTERM) {
                    return 5;
                }

                char chunk[64 * 1024];
                memset(chunk, 'x', sizeof(chunk));
                for (int index = 0; index < \(Self.payloadByteCount / (64 * 1024)); ++index) {
                    if (write_all(STDERR_FILENO, chunk, sizeof(chunk)) != 0) {
                        return 6;
                    }
                }

                char cwd[4096];
                if (getcwd(cwd, sizeof(cwd)) == NULL) {
                    return 7;
                }
                if (write_all(STDOUT_FILENO, cwd, strlen(cwd)) != 0 ||
                    write_all(STDOUT_FILENO, "\\n", 1) != 0) {
                    return 8;
                }

                int output_gate_fd = open(\(outputGatePathLiteral), O_WRONLY);
                if (output_gate_fd < 0 ||
                    write_all(output_gate_fd, "gated\\n", 6) != 0) {
                    return 9;
                }
                close(output_gate_fd);

                int release_fd = open(\(releasePathLiteral), O_RDONLY);
                if (release_fd < 0) {
                    return 10;
                }
                char release = 0;
                while (read(release_fd, &release, 1) < 0 && errno == EINTR) {
                }
                close(release_fd);
                return 0;
            }
            """
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            let compile = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
                arguments: [sourceURL.path, "-o", executableURL.path]
            )
            guard compile.terminationStatus == 0 else {
                throw NSError(
                    domain: "GitServiceCancellationTests.compile",
                    code: Int(compile.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: compile.outputText]
                )
            }

            self.sandbox = sandbox
            self.repo = repo
            self.executableURL = executableURL
            self.expectedOutputByteCount = expectedOutputByteCount
            self.readyDescriptor = readyDescriptor
            self.outputGateDescriptor = outputGateDescriptor
            self.releaseDescriptor = releaseDescriptor
            shouldCloseDescriptors = false
            shouldRemoveSandbox = false
        }

        func cleanup() {
            _ = Darwin.close(readyDescriptor)
            _ = Darwin.close(outputGateDescriptor)
            _ = Darwin.close(releaseDescriptor)
            try? FileManager.default.removeItem(at: sandbox)
        }

        func awaitReadyPID() async throws -> pid_t {
            let data = try await readSignal(from: readyDescriptor)
            guard let text = String(data: data, encoding: .ascii),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw POSIXError(.EIO)
            }
            return pid
        }

        func awaitOutputGate() async throws {
            let data = try await readSignal(from: outputGateDescriptor)
            guard data == Data("gated\n".utf8) else {
                throw POSIXError(.EIO)
            }
        }

        func releaseChild() throws {
            var release: UInt8 = 1
            guard Darwin.write(releaseDescriptor, &release, 1) == 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        private func readSignal(from descriptor: Int32) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let pollResult = Darwin.poll(&pollDescriptor, 1, 5000)
                    guard pollResult > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else {
                        let code = pollResult == 0 ? ETIMEDOUT : errno
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                        return
                    }

                    var buffer = [UInt8](repeating: 0, count: 64)
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    guard count > 0 else {
                        continuation.resume(throwing: POSIXError(.EIO))
                        return
                    }
                    continuation.resume(returning: Data(buffer.prefix(Int(count))))
                }
            }
        }

        private static func cStringLiteral(_ value: String) throws -> String {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class TestCompletionSignal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func signal() {
            semaphore.signal()
        }

        func wait(timeout: Duration) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.semaphore.wait(timeout: .now() + timeout.timeInterval)
                    continuation.resume(returning: result == .success)
                }
            }
        }
    }

    private extension Duration {
        var timeInterval: TimeInterval {
            let components = components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }
#endif
