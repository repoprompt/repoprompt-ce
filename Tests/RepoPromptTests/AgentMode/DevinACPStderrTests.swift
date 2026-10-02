import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class DevinACPStderrTests: XCTestCase {
    private static let warning = "2026-10-01T16:04:15.144229Z  WARN run_acp_server: config_importers::importers::mcp: [MCP] environment variable 'MISSING_TEST_KEY' is not set; substituting empty string"
    private static let answer = "2026-10-01T16:04:15Z WARN quoted model content must remain intact"

    func testHeadlessRouteDoesNotStreamProcessStderrAsAnswer() async throws {
        let config = try makeConfig()
        let provider = DevinACPHeadlessAgentProvider(config: config, controllerFactory: { provider, request, sink in
            try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: { event in
                sink?(event)
                Self.acknowledgeWarning(event, config: config)
            })
        })
        let message = AgentMessage(userMessage: "Describe this")
        var results: [AIStreamResult] = []
        do {
            for try await result in try await provider.streamAgentMessage(message) {
                results.append(result)
            }
            await provider.dispose()
        } catch {
            await provider.dispose()
            throw error
        }
        XCTAssertEqual(results.filter { $0.type == "content" }.compactMap(\.text).joined(), Self.answer)
        XCTAssertFalse(results.contains { $0.type == "system" })
        XCTAssertFalse(results.compactMap(\.text).joined().contains(Self.warning))
    }

    func testAgentModeEventsKeepStderrInDiagnosticsNotTranscript() async throws {
        let config = try makeConfig()
        let request = makeRequest()
        let diagnostics = DiagnosticRecorder()
        let controller = try ACPAgentSessionController(
            provider: DevinACPAgentProvider(config: config),
            runRequest: request,
            diagnosticSink: { event in
                if case let .stderrLine(line) = event { diagnostics.append(line) }
                Self.acknowledgeWarning(event, config: config)
            }
        )
        let events = await controller.events
        let collected = Task { () -> [AIStreamResult] in
            var results: [AIStreamResult] = []
            for await event in events {
                if case let .stream(result) = event { results.append(result) }
            }
            return results
        }
        do {
            _ = try await controller.bootstrap()
            try await controller.prompt(AgentMessage(userMessage: "hi"), request: request)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            _ = await collected.value
            throw error
        }
        let results = await collected.value
        XCTAssertTrue(diagnostics.lines.contains(Self.warning))
        XCTAssertEqual(results.filter { $0.type == "content" }.compactMap(\.text).joined(), Self.answer)
        XCTAssertFalse(results.contains { $0.type == "system" })
    }

    func testStartupFailureSurfacesStderrWithoutCreatingSystemRows() async throws {
        let config = try makeConfig(failStartup: true)
        let controller = try ACPAgentSessionController(provider: DevinACPAgentProvider(config: config), runRequest: makeRequest())
        let events = await controller.events
        let collected = Task { () -> [AIStreamResult] in
            var results: [AIStreamResult] = []
            for await event in events {
                if case let .stream(result) = event { results.append(result) }
            }
            return results
        }
        do {
            _ = try await controller.bootstrap()
            XCTFail("expected failed session/new")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission denied while reading test config"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 7"), error.localizedDescription)
        }
        await controller.shutdown()
        let results = await collected.value
        XCTAssertFalse(results.contains { $0.type == "system" })
        XCTAssertTrue(results.contains { $0.type == "error" && ($0.text?.contains("permission denied") == true) })
    }

    func testPromptFailureRetainsFinalStderrDiagnostic() async throws {
        let config = try makeConfig(failPrompt: true)
        let provider = DevinACPHeadlessAgentProvider(config: config)
        do {
            let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "hi"))
            for try await result in stream {
                XCTAssertNotEqual(result.type, "system")
            }
            XCTFail("expected prompt process failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("authentication failed during test prompt"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 9"), error.localizedDescription)
        }
        await provider.dispose()
    }

    func testFailureFlushesBufferedDiagnosticWhenDescendantKeepsStderrOpen() async throws {
        let config = try makeConfig(failStartup: true, holdStderr: true)
        let directory = URL(fileURLWithPath: config.commandName).deletingLastPathComponent()
        let release = directory.appendingPathComponent("release-stderr")
        defer { try? Data().write(to: release) }
        let warningObserved = expectation(description: "fixture stderr chunk consumed")
        let controller = try ACPAgentSessionController(
            provider: DevinACPAgentProvider(config: config),
            runRequest: makeRequest(),
            diagnosticSink: { event in
                Self.acknowledgeWarning(event, config: config)
                if case let .stderrLine(line) = event, line == Self.warning { warningObserved.fulfill() }
            }
        )
        let settled = expectation(description: "process failure settles without waiting for descendant EOF")
        let bootstrap = Task { () -> String? in
            defer { settled.fulfill() }
            do {
                _ = try await controller.bootstrap()
                return nil
            } catch { return error.localizedDescription }
        }
        await fulfillment(of: [warningObserved], timeout: 10)
        // Bound only exit settlement, not unrelated process/environment startup.
        await fulfillment(of: [settled], timeout: 2)
        // Release only our fixture descendant, including when the assertion times out.
        try Data().write(to: release)
        let errorText = await bootstrap.value ?? "bootstrap unexpectedly succeeded"
        await controller.shutdown()
        XCTAssertTrue(errorText.contains("permission denied while reading test config"), errorText)
        XCTAssertTrue(errorText.contains("code 7"), errorText)
    }

    private static func acknowledgeWarning(_ event: ACPAgentSessionController.DiagnosticEvent, config: DevinAgentConfig) {
        guard case let .stderrLine(line) = event, line == warning else { return }
        let marker = URL(fileURLWithPath: config.commandName).deletingLastPathComponent().appendingPathComponent("stderr-observed")
        try? Data().write(to: marker)
    }

    private func makeRequest() -> ACPRunRequest {
        ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: nil, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
    }

    private func makeConfig(failStartup: Bool = false, failPrompt: Bool = false, holdStderr: Bool = false) throws -> DevinAgentConfig {
        let directory = try makeTestDirectory(name: "DevinACPStderrTests")
        let executable = directory.appendingPathComponent("devin")
        let script = try #"""
        #!/usr/bin/env python3
        import json, os, pathlib, sys, time
        if "--help" in sys.argv:
            print("Run as an ACP server over stdio")
            sys.exit(0)
        FAIL_STARTUP = __FAIL_STARTUP__
        FAIL_PROMPT = __FAIL_PROMPT__
        HOLD_STDERR = __HOLD_STDERR__
        WARNING = __WARNING__
        ANSWER = __ANSWER__
        def respond(id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": id, "result": result}), flush=True)
        def wait_for_warning():
            marker = pathlib.Path(__file__).with_name("stderr-observed")
            deadline = time.monotonic() + 5
            while not marker.exists():
                if time.monotonic() > deadline:
                    sys.exit(10)
                time.sleep(0.005)
        for line in sys.stdin:
            msg = json.loads(line)
            method = msg.get("method")
            if method == "initialize":
                respond(msg["id"], {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": True}}, "authMethods": []})
            elif method == "session/new":
                if HOLD_STDERR:
                    if os.fork() == 0:
                        # Keep the inherited write FD open until our test releases it.
                        release = pathlib.Path(__file__).with_name("release-stderr")
                        deadline = time.monotonic() + 5
                        while not release.exists() and time.monotonic() < deadline:
                            time.sleep(0.005)
                        os._exit(0)
                    # One write lets the diagnostic callback acknowledge the same
                    # framed chunk that retains the final unterminated error tail.
                    os.write(sys.stderr.fileno(), (WARNING + "\npermission denied while reading test config").encode())
                    wait_for_warning()
                    sys.exit(7)
                print(WARNING, file=sys.stderr, flush=True)
                if FAIL_STARTUP:
                    print("permission denied while reading test config", file=sys.stderr, end="", flush=True)
                    sys.exit(7)
                if not FAIL_PROMPT:
                    # Complete only after the controller's diagnostic sink saw FD stderr.
                    wait_for_warning()
                respond(msg["id"], {"sessionId": "devin-stderr-session"})
            elif method == "session/prompt":
                if FAIL_PROMPT:
                    print("authentication failed during test prompt", file=sys.stderr, end="", flush=True)
                    sys.exit(9)
                print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "devin-stderr-session", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": ANSWER}}}}), flush=True)
                respond(msg["id"], {"stopReason": "end_turn"})
            elif "id" in msg:
                respond(msg["id"], {})
        """#
        .replacingOccurrences(of: "__FAIL_STARTUP__", with: failStartup ? "True" : "False")
        .replacingOccurrences(of: "__FAIL_PROMPT__", with: failPrompt ? "True" : "False")
        .replacingOccurrences(of: "__HOLD_STDERR__", with: holdStderr ? "True" : "False")
        .replacingOccurrences(of: "__WARNING__", with: String(data: JSONEncoder().encode(Self.warning), encoding: .utf8)!)
        .replacingOccurrences(of: "__ANSWER__", with: String(data: JSONEncoder().encode(Self.answer), encoding: .utf8)!) + "\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return DevinAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false)
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] {
        lock.withLock { storage }
    }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}
