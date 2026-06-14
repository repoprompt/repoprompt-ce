import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class ProcessLauncherDescriptorInheritanceTests: XCTestCase {
    func testParentPipeEndsHaveCloseOnExecAndChildStdioStillWorks() throws {
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "IFS= read -r line; printf 'stdout:%s\\n' \"$line\"; printf 'stderr:ok\\n' >&2"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil
        )
        defer { Self.cleanup(spawned) }

        let stdinFD = try XCTUnwrap(spawned.stdinDescriptor)
        XCTAssertTrue(Self.hasCloseOnExec(stdinFD))
        XCTAssertTrue(Self.hasCloseOnExec(spawned.stdout.fileDescriptor))
        XCTAssertTrue(Self.hasCloseOnExec(spawned.stderr.fileDescriptor))

        try spawned.stdin?.write(contentsOf: Data("sentinel-line\n".utf8))
        spawned.stdin?.closeFile()

        let stdout = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: spawned.stderr.readDataToEndOfFile(), as: UTF8.self)
        let status = try Self.waitForExit(spawned.pid)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(stdout, "stdout:sentinel-line\n")
        XCTAssertEqual(stderr, "stderr:ok\n")
    }

    func testDarwinSpawnDefaultClosesUnrelatedSentinelFDWhileStdioStillWorks() throws {
        var sentinelPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&sentinelPipe), 0)
        defer {
            Self.closeIfOpen(sentinelPipe[0])
            Self.closeIfOpen(sentinelPipe[1])
        }

        let sentinelFD = fcntl(sentinelPipe[0], F_DUPFD, 100)
        XCTAssertGreaterThanOrEqual(sentinelFD, 100)
        defer { Self.closeIfOpen(sentinelFD) }
        let flags = fcntl(sentinelFD, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertGreaterThanOrEqual(fcntl(sentinelFD, F_SETFD, flags & ~FD_CLOEXEC), 0)
        XCTAssertFalse(Self.hasCloseOnExec(sentinelFD))
        var sentinelIdentityBeforeSpawn = stat()
        XCTAssertEqual(fstat(sentinelFD, &sentinelIdentityBeforeSpawn), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["SENTINEL_FD"] = String(sentinelFD)
        let script = "if [ -e \"/dev/fd/$SENTINEL_FD\" ]; then printf 'sentinel:open\\n'; else printf 'sentinel:closed\\n'; fi; IFS= read -r line; printf 'stdout:%s\\n' \"$line\"; printf 'stderr:ok\\n' >&2"
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            workingDirectory: nil
        )
        defer { Self.cleanup(spawned) }

        // File descriptor numbers are process-global and can be reused by unrelated async cleanup.
        // Check identity before child I/O so a failure is attributable to the synchronous spawn call.
        var sentinelIdentityAfterSpawn = stat()
        XCTAssertEqual(fstat(sentinelFD, &sentinelIdentityAfterSpawn), 0, "Spawn must not close the parent sentinel")
        XCTAssertEqual(sentinelIdentityAfterSpawn.st_dev, sentinelIdentityBeforeSpawn.st_dev)
        XCTAssertEqual(sentinelIdentityAfterSpawn.st_ino, sentinelIdentityBeforeSpawn.st_ino)
        XCTAssertEqual(sentinelIdentityAfterSpawn.st_mode, sentinelIdentityBeforeSpawn.st_mode)

        try spawned.stdin?.write(contentsOf: Data("stdio-survives\n".utf8))
        spawned.stdin?.closeFile()

        let stdout = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: spawned.stderr.readDataToEndOfFile(), as: UTF8.self)
        let status = try Self.waitForExit(spawned.pid)

        XCTAssertEqual(status, 0)
        XCTAssertTrue(stdout.contains("sentinel:closed\n"), stdout)
        XCTAssertTrue(stdout.contains("stdout:stdio-survives\n"), stdout)
        XCTAssertEqual(stderr, "stderr:ok\n")
    }

    func testEstablishedSessionObservesEOFWhileSpawnedChildRemainsAlive() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { Self.closeIfOpen(descriptors[1]) }

        let sessionFD = fcntl(descriptors[0], F_DUPFD, 100)
        XCTAssertGreaterThanOrEqual(sessionFD, 100)
        Self.closeIfOpen(descriptors[0])
        defer { Self.closeIfOpen(sessionFD) }
        let flags = fcntl(sessionFD, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertGreaterThanOrEqual(fcntl(sessionFD, F_SETFD, flags & ~FD_CLOEXEC), 0)
        XCTAssertFalse(Self.hasCloseOnExec(sessionFD))

        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sleep",
            arguments: ["5"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil
        )
        defer { Self.cleanup(spawned) }

        XCTAssertTrue(Self.processIsRunning(spawned.pid))
        Self.closeIfOpen(sessionFD)

        XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
        XCTAssertTrue(Self.processIsRunning(spawned.pid), "Child should remain alive while established session EOF arrives")
    }

    func testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { Self.closeIfOpen(descriptors[1]) }

        let sessionFD = fcntl(descriptors[0], F_DUPFD, 100)
        XCTAssertGreaterThanOrEqual(sessionFD, 100)
        Self.closeIfOpen(descriptors[0])
        defer { Self.closeIfOpen(sessionFD) }

        let transport = try UnixSocketMCPTransport(connectedFD: sessionFD)
        try await transport.connect()
        do {
            let receiveStream = await transport.receive()
            try Self.writeAll(Data("peer-probe\n".utf8), to: descriptors[1])
            let receivedProbe = try await Self.firstReceivedMessage(from: receiveStream)
            XCTAssertEqual(receivedProbe, Data("peer-probe".utf8))

            try await transport.send(Data("transport-probe".utf8))
            XCTAssertEqual(
                try Self.readExactly("transport-probe\n".utf8.count, from: descriptors[1]),
                Data("transport-probe\n".utf8)
            )

            var environment = ProcessInfo.processInfo.environment
            environment["SESSION_FD"] = String(sessionFD)
            let script = "if [ -e \"/dev/fd/$SESSION_FD\" ]; then printf 'session:open\\n'; else printf 'session:closed\\n'; fi; sleep 5"
            let spawned = try ProcessLauncher.spawn(
                command: "/bin/sh",
                arguments: ["-c", script],
                environment: environment,
                workingDirectory: nil
            )
            defer { Self.cleanup(spawned) }

            let childReport = try String(
                decoding: Self.readExactly("session:closed\n".utf8.count, from: spawned.stdout.fileDescriptor),
                as: UTF8.self
            )
            XCTAssertEqual(childReport, "session:closed\n")
            XCTAssertTrue(Self.processIsRunning(spawned.pid))

            try await transport.send(Data("still-active".utf8))
            XCTAssertEqual(
                try Self.readExactly("still-active\n".utf8.count, from: descriptors[1]),
                Data("still-active\n".utf8)
            )

            await transport.disconnect()
            XCTAssertTrue(Self.waitUntilClosed(sessionFD))
            XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
            XCTAssertTrue(Self.processIsRunning(spawned.pid), "Child should remain alive while active transport EOF arrives")
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    func testInjectedSpawnInitializationFailuresReturnTypedErrors() throws {
        #if DEBUG
            XCTAssertThrowsError(
                try ProcessLauncher.debugSpawn(
                    command: "/bin/true",
                    arguments: [],
                    environment: ProcessInfo.processInfo.environment,
                    workingDirectory: nil,
                    initializationFailure: .fileActions(errno: ENOMEM)
                )
            ) { error in
                guard case let ProcessLauncherError.spawnFileActionsFailed(operation, errnoValue) = error else {
                    return XCTFail("Unexpected file-actions initialization error: \(error)")
                }
                XCTAssertEqual(operation, "init")
                XCTAssertEqual(errnoValue, ENOMEM)
            }

            XCTAssertThrowsError(
                try ProcessLauncher.debugSpawn(
                    command: "/bin/true",
                    arguments: [],
                    environment: ProcessInfo.processInfo.environment,
                    workingDirectory: nil,
                    initializationFailure: .attributes(errno: ENOMEM)
                )
            ) { error in
                guard case let ProcessLauncherError.spawnAttributesFailed(operation, errnoValue) = error else {
                    return XCTFail("Unexpected attributes initialization error: \(error)")
                }
                XCTAssertEqual(operation, "init")
                XCTAssertEqual(errnoValue, ENOMEM)
            }
        #else
            throw XCTSkip("ProcessLauncher initializer failure seams are DEBUG-only")
        #endif
    }

    func testLauncherSourcesCheckSpawnFileActionAndAttributeInitializationResults() throws {
        let root = try RepoRoot.url()
        let launcher = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift"),
            encoding: .utf8
        )
        let runner = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/Process/CLIProcessRunner.swift"),
            encoding: .utf8
        )

        Self.assertSourceContains(
            [
                "let fileActionsInitResult: Int32 = if case let .fileActions(errno)? = initializationFailure",
                "posix_spawn_file_actions_init(&fileActions)",
                "if fileActionsInitResult != 0 {",
                "throw ProcessLauncherError.spawnFileActionsFailed(operation: \"init\", errno: fileActionsInitResult)",
                "try checkFileAction(\"adddup2(stdin)\", result: posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO))",
                "try checkFileAction(\"addclose(stderr read)\", result: posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]))",
                "let attributesInitResult: Int32 = if case let .attributes(errno)? = initializationFailure",
                "posix_spawnattr_init(&attributes)",
                "if attributesInitResult != 0 {",
                "throw ProcessLauncherError.spawnAttributesFailed(operation: \"init\", errno: attributesInitResult)",
                "let getFlagsResult = posix_spawnattr_getflags(&attributes, &spawnFlags)",
                "if getFlagsResult != 0 {",
                "let setSigDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)",
                "if setSigDefaultResult != 0 {",
                "let setFlagsResult = posix_spawnattr_setflags(&attributes, configuredSpawnFlags)",
                "if setFlagsResult != 0 {"
            ],
            in: launcher
        )
        Self.assertSourceContains(
            [
                "catch let launcherError as ProcessLauncherError",
                "throw mapLauncherError(launcherError, command: resolvedCommand, workingDirectory: workingDirectory)",
                "case let .spawnFileActionsFailed(operation, errnoValue):",
                "case let .spawnAttributesFailed(operation, errnoValue):"
            ],
            in: runner
        )
    }

    private static func assertSourceContains(
        _ snippets: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for snippet in snippets {
            XCTAssertTrue(source.contains(snippet), "Missing ProcessLauncher result check: \(snippet)", file: file, line: line)
        }
    }

    private static func firstReceivedMessage(
        from stream: AsyncThrowingStream<Data, Swift.Error>
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw TestError.transportReceiveTimedOut
            }
            guard let message = try await group.next() else {
                throw TestError.transportReceiveTimedOut
            }
            group.cancelAll()
            return message
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func readExactly(_ count: Int, from fd: Int32, timeout: TimeInterval = 2) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while data.count < count, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let received = Darwin.read(fd, &buffer, buffer.count)
            if received > 0 {
                data.append(contentsOf: buffer.prefix(Int(received)))
            } else if received == 0 {
                throw TestError.unexpectedEOF
            } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard data.count == count else { throw TestError.readTimedOut }
        return data
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return Darwin.waitpid(pid, &status, WNOHANG) == 0 && Darwin.kill(pid, 0) == 0
    }

    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval = 3) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
            usleep(20000)
        }
        throw TestError.childDidNotExit(pid)
    }

    private static func cleanup(_ spawned: SpawnedProcess) {
        spawned.stdin?.closeFile()
        spawned.stdout.closeFile()
        spawned.stderr.closeFile()

        var status: Int32 = 0
        let result = Darwin.waitpid(spawned.pid, &status, WNOHANG)
        if result == 0 {
            _ = Darwin.kill(spawned.pid, SIGTERM)
            _ = Darwin.waitpid(spawned.pid, &status, 0)
        }
    }

    private static func peerObservedEOF(on fd: Int32, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else { continue }

            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            if count == 0 { return true }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK { return false }
        }
        return false
    }

    private static func waitUntilClosed(_ fd: Int32, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isClosed(fd) { return true }
            usleep(20000)
        }
        return isClosed(fd)
    }

    private static func hasCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    private static func isClosed(_ fd: Int32) -> Bool {
        errno = 0
        return fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0, !isClosed(fd) else { return }
        Darwin.close(fd)
    }
}

private enum TestError: Error {
    case childDidNotExit(pid_t)
    case readTimedOut
    case transportReceiveTimedOut
    case unexpectedEOF
}
