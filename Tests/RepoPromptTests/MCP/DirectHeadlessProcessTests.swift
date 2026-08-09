#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessProcessTests: XCTestCase {
    func testDirectProcessChildEnvironmentUsesAllowlistAndPrivateCarrier() {
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/tmp/home",
            "TMPDIR": "/tmp/",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            "OPENAI_API_KEY": "secret-openai",
            "AWS_SECRET_ACCESS_KEY": "secret-aws",
            "SSH_AUTH_SOCK": "/tmp/ssh-agent",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            "REPOPROMPT_CODEX_COMMAND": "/tmp/codex"
        ]
        let carrier = [
            "REPOPROMPT_MCP_PRIVATE_ENDPOINT": "unix:///tmp/private.sock",
            "REPOPROMPT_MCP_LAUNCH_TOKEN": "single-use-token",
            "REPOPROMPT_MCP_CREDENTIAL_ENVELOPE": "envelope-id",
            "REPOPROMPT_MCP_CLIENT_PRINCIPAL": "headless-client",
            "REPOPROMPT_MCP_PROVIDER_IDENTIFIER": "codex",
            "REPOPROMPT_MCP_RUN_ID": UUID().uuidString
        ]
        let overrides = inherited.merging(carrier) { _, supplied in supplied }
        let child = DirectProcess.childEnvironment(inherited: inherited, overrides: overrides)

        XCTAssertEqual(child["PATH"], inherited["PATH"])
        XCTAssertEqual(child["HOME"], inherited["HOME"])
        XCTAssertEqual(child["LC_CTYPE"], inherited["LC_CTYPE"])
        XCTAssertEqual(child["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(child["LC_ALL"], "C")
        for (key, value) in carrier {
            XCTAssertEqual(child[key], value, "carrier key=\(key)")
        }
        for key in ["OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY", "SSH_AUTH_SOCK", "DYLD_INSERT_LIBRARIES", "REPOPROMPT_CODEX_COMMAND"] {
            XCTAssertNil(child[key], "unexpected inherited key=\(key)")
        }
    }

    func testDirectProcessStripsStalePrivateCarrierBeforeCurrentCarrierMerge() {
        let staleCarrier = [
            "REPOPROMPT_MCP_PRIVATE_ENDPOINT": "unix:///tmp/stale.sock",
            "REPOPROMPT_MCP_LAUNCH_TOKEN": "stale-token",
            "REPOPROMPT_MCP_CREDENTIAL_ENVELOPE": "stale-envelope",
            "REPOPROMPT_MCP_CLIENT_PRINCIPAL": "stale-client",
            "REPOPROMPT_MCP_PROVIDER_IDENTIFIER": "stale-provider",
            "REPOPROMPT_MCP_RUN_ID": "stale-run"
        ]
        let currentCarrier = [
            "REPOPROMPT_MCP_PRIVATE_ENDPOINT": "unix:///tmp/current.sock",
            "REPOPROMPT_MCP_LAUNCH_TOKEN": "current-token"
        ]
        let inherited = ["PATH": "/usr/bin:/bin"].merging(staleCarrier) { _, supplied in supplied }
        let sanitized = DirectProcess.withoutPrivateCarrier(from: inherited)
        let child = DirectProcess.childEnvironment(
            inherited: inherited,
            overrides: sanitized.merging(currentCarrier) { _, supplied in supplied }
        )

        for (key, value) in currentCarrier {
            XCTAssertEqual(child[key], value, "carrier key=\(key)")
        }
        for (key, value) in staleCarrier where currentCarrier[key] == nil {
            XCTAssertNil(child[key], "stale carrier key=\(key) value=\(value)")
        }
    }

    func testDirectProcessLaunchesRootInOwnProcessGroup() async throws {
        let output = try await DirectProcess.run(
            "/bin/sh",
            arguments: ["-c", "printf '%s %s\\n' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\""]
        )
        let identifiers = output.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32(String($0)) }

        XCTAssertEqual(identifiers.count, 2, output)
        XCTAssertEqual(identifiers.first, identifiers.last, output)
    }

    func testDirectProcessPreservesInputWorkingDirectoryAndMergedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-process-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = try await DirectProcess.run(
            "/bin/sh",
            arguments: [
                "-c",
                "printf 'stdout:%s\\n' \"$PWD\"; IFS= read -r line; printf 'stderr:%s\\n' \"$line\" >&2"
            ],
            input: Data("carrier-input\n".utf8),
            currentDirectory: directory
        )

        XCTAssertTrue(output.contains("stdout:\(directory.path)\n"), output)
        XCTAssertTrue(output.contains("stderr:carrier-input\n"), output)
    }

    func testDirectProcessCancellationTerminatesReparentedProcessGroupDescendant() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-process-descendant-\(UUID().uuidString).pid")
        let rootMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-process-root-\(UUID().uuidString).pid")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: rootMarker)
        }
        let descendantScript = "printf \"%s\\n\" \"$$\" > \"$2\"; "
            + "( /bin/sh -c 'test \"$REPOPROMPT_MCP_LAUNCH_TOKEN\" = test-launch-token || exit 91; "
            + "trap \"\" TERM; printf \"%s\\n\" \"$$\" > \"$1\"; "
            + "while :; do sleep 1; done' child \"$1\" & ); while :; do sleep 1; done"

        let task = Task {
            try await DirectProcess.run(
                "/bin/sh",
                arguments: [
                    "-c",
                    descendantScript,
                    "root",
                    marker.path,
                    rootMarker.path
                ],
                environment: ["REPOPROMPT_MCP_LAUNCH_TOKEN": "test-launch-token"]
            )
        }
        defer { task.cancel() }

        let rootPID = try await Self.waitForPIDFile(rootMarker)
        let descendantPID = try await Self.waitForPIDFile(marker)
        defer {
            if Self.processExists(rootPID) {
                Self.signalProcessGroup(rootPID, SIGKILL)
                Self.signal(rootPID, SIGKILL)
            }
            if Self.processExists(descendantPID) {
                Self.signal(descendantPID, SIGKILL)
            }
        }
        XCTAssertTrue(Self.processExists(descendantPID))

        task.cancel()
        let completion = expectation(description: "DirectProcess cancellation completed")
        let resultBox = DirectProcessTaskResultBox()
        Task {
            resultBox.store(await task.result)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 4)
        guard let result = resultBox.result else {
            XCTFail("DirectProcess cancellation did not finish within the bounded grace period")
            return
        }
        switch result {
        case .success:
            XCTFail("Expected DirectProcess cancellation")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "Unexpected cancellation error: \(error)")
        }

        let descendantGone = await Self.waitUntilProcessGone(descendantPID)
        XCTAssertTrue(
            descendantGone,
            "Reparented same-process-group descendant should not survive DirectProcess cancellation"
        )
    }

    func testNoAppHeadlessProcessListsCanonicalPolicySurfaceAndDrainsOnEOF() throws {
        let executable = try Self.executableURL()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-process-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--backend", "headless"]
        var environment = ProcessInfo.processInfo.environment
        environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = profile.path
        environment["REPOPROMPT_MCP_WORKING_DIRS"] = root.path
        environment.removeValue(forKey: "REPOPROMPT_MCP_PRIVATE_ENDPOINT")
        environment.removeValue(forKey: "REPOPROMPT_MCP_LAUNCH_TOKEN")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        try Self.writeJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "headless-process-test", "version": "1"]
            ]
        ], to: input.fileHandleForWriting)
        _ = try Self.readJSONLine(from: output.fileHandleForReading)
        try Self.writeJSON([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:]
        ], to: input.fileHandleForWriting)
        let list = try Self.readJSONLine(from: output.fileHandleForReading)
        let result = try XCTUnwrap(list["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 20)
        let bind = try XCTUnwrap(tools.first { $0["name"] as? String == "bind_context" })
        let bindSchema = try JSONSerialization.data(withJSONObject: bind["inputSchema"] as Any)
        XCTAssertFalse(String(decoding: bindSchema, as: UTF8.self).contains("window_id"))

        let fixturePath = root.appendingPathComponent("Package.swift").path
        let fixtureBefore = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let invocationArguments: [String: [String: Any]] = [
            "app_settings": ["op": "list"],
            "bind_context": ["op": "status"],
            "manage_workspaces": ["action": "list"],
            "manage_selection": ["op": "set", "paths": ["Package.swift"]],
            "file_actions": ["action": "create", "path": profile.appendingPathComponent("denied.txt").path, "content": "denied"],
            "get_code_structure": ["paths": [fixturePath], "signatures": false],
            "get_file_tree": ["type": "roots"],
            "read_file": ["path": fixturePath, "start_line": 1, "limit": 1],
            "file_search": ["pattern": "swift-tools-version", "path": fixturePath, "regex": false],
            "workspace_context": ["op": "snapshot"],
            "prompt": ["op": "set", "text": "headless process context mutation"],
            "apply_edits": ["path": fixturePath, "search": "not-present", "replace": "never"],
            "oracle_utils": ["op": "models"],
            "oracle_send": ["chat_id": UUID().uuidString, "message": "continue"],
            "context_builder": ["instructions": "Inspect the workspace"],
            "git": ["op": "status"],
            "manage_worktree": ["op": "list"],
            "agent_run": ["op": "poll", "session_id": UUID().uuidString],
            "agent_manage": ["op": "list_agents", "roles_only": true],
            "history": ["op": "list_sessions"]
        ]
        let advertisedNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(
            advertisedNames,
            Set(invocationArguments.keys),
            "missing fixtures=\(advertisedNames.subtracting(invocationArguments.keys)); extra fixtures=\(Set(invocationArguments.keys).subtracting(advertisedNames))"
        )
        var toolResults: [String: [String: Any]] = [:]
        for (offset, tool) in tools.enumerated() {
            let name = try XCTUnwrap(tool["name"] as? String)
            let arguments = try XCTUnwrap(invocationArguments[name])
            let requestID = 100 + offset
            try Self.writeJSON([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/call",
                "params": ["name": name, "arguments": arguments]
            ], to: input.fileHandleForWriting)
            let reply = try Self.readJSONLine(from: output.fileHandleForReading)
            XCTAssertEqual(reply["id"] as? Int, requestID, "tool=\(name)")
            XCTAssertNil(reply["error"], "tool=\(name) reply=\(reply)")
            let callResult = try XCTUnwrap(reply["result"] as? [String: Any], "tool=\(name) reply=\(reply)")
            toolResults[name] = callResult
        }
        let expectedDenied = Set(["file_actions", "apply_edits", "oracle_send", "context_builder"])
        for (name, result) in toolResults {
            XCTAssertEqual(result["isError"] as? Bool ?? false, expectedDenied.contains(name), "tool=\(name) result=\(result)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("denied.txt").path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixturePath)), fixtureBefore)

        let deniedExportPath = root.appendingPathComponent(".build/denied-headless-process-export-\(UUID().uuidString).txt")
        try Self.writeJSON([
            "jsonrpc": "2.0",
            "id": 500,
            "method": "tools/call",
            "params": [
                "name": "prompt",
                "arguments": ["op": "export", "path": deniedExportPath.path]
            ]
        ], to: input.fileHandleForWriting)
        let deniedExportReply = try Self.readJSONLine(from: output.fileHandleForReading)
        let deniedExportResult = try XCTUnwrap(deniedExportReply["result"] as? [String: Any])
        XCTAssertEqual(deniedExportResult["isError"] as? Bool, true)
        let deniedContent = try XCTUnwrap(deniedExportResult["content"] as? [[String: Any]])
        XCTAssertTrue(deniedContent.description.contains("grantMissing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedExportPath.path))

        try input.fileHandleForWriting.close()
        let exited = expectation(description: "bounded EOF drain")
        process.terminationHandler = { _ in exited.fulfill() }
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(process.terminationStatus, 0)
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: stderr, as: UTF8.self), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Workspaces").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Headless").path))
    }

    func testNonAppBackendsRejectInteractiveAndExecModes() throws {
        for arguments in [
            ["--backend", "headless", "--interactive"],
            ["--backend", "headless", "-e", "windows"],
            ["--backend", "auto", "--interactive"],
            ["--backend", "auto", "-e", "windows"]
        ] {
            let process = Process()
            process.executableURL = try Self.executableURL()
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 2, "arguments=\(arguments)")
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(stderr.contains(arguments[1]))
            XCTAssertTrue(stderr.contains("interactive and exec"))
        }
    }

    func testBackendParserRejectsBareAndDuplicateBackendArguments() throws {
        let cases = [
            ["auto"],
            ["app"],
            ["headless"],
            ["--backend", "app", "--backend", "auto"],
            ["--backend=app", "--backend=headless"]
        ]
        for arguments in cases {
            let process = Process()
            process.executableURL = try Self.executableURL()
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 2, "arguments=\(arguments)")
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if arguments.count == 1 {
                XCTAssertTrue(stderr.contains("no command or mode specified"), "arguments=\(arguments) stderr=\(stderr)")
            } else {
                XCTAssertTrue(stderr.contains("specified only once"), "arguments=\(arguments) stderr=\(stderr)")
            }
        }
    }

    private static func executableURL() throws -> URL {
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = cursor.appendingPathComponent("repoprompt-mcp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/repoprompt-mcp")
        guard FileManager.default.isExecutableFile(atPath: fallback.path) else {
            throw XCTSkip("repoprompt-mcp product is not built")
        }
        return fallback
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func readJSONLine(from handle: FileHandle) throws -> [String: Any] {
        var data = Data()
        while true {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            if byte[0] == 0x0A { break }
            data.append(byte)
            guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func waitForPIDFile(_ url: URL, timeout: TimeInterval = 3) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw DirectHeadlessProcessTestError.pidFileTimedOut
    }

    private static func waitUntilProcessGone(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !processExists(pid) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !processExists(pid)
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        if systemKill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func signal(_ pid: pid_t, _ signal: Int32) {
        _ = systemKill(pid, signal)
    }

    private static func signalProcessGroup(_ processGroupID: pid_t, _ signal: Int32) {
        _ = systemKill(-processGroupID, signal)
    }

    private static func systemKill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.kill(pid, signal)
        #else
            Glibc.kill(pid, signal)
        #endif
    }
}

private enum DirectHeadlessProcessTestError: Error {
    case pidFileTimedOut
}

private final class DirectProcessTaskResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<String, Error>?

    var result: Result<String, Error>? {
        lock.withLock { storage }
    }

    func store(_ result: Result<String, Error>) {
        lock.withLock { storage = result }
    }
}
