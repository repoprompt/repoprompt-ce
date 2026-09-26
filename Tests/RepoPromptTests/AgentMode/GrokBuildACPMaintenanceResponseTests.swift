import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Grok Build's discovery watcher sends its own internal requests (`skills-reload`,
/// `workflows-reload`) and writes their replies to the stdout stream the ACP client reads
/// (#1038). These tests drive the real Grok provider and ACP session controller against a
/// fake `grok` process. While owned work is pending, the fake writes such a reply, then sends
/// an unsupported server request and waits for the controller's `-32601` answer, which shows
/// the controller kept processing, before it delivers the owned reply. A maintenance reply
/// must not settle, fail or cancel owned work. Frames are synthetic and source-derived.
final class GrokBuildACPMaintenanceResponseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testMaintenanceReplyDuringPromptLeavesTurnIntact() async throws {
        let cases: [(label: String, frames: [String], maintenanceID: String)] = [
            ("skills", [MaintenanceFrame.skills], "skills-reload"),
            ("workflows", [MaintenanceFrame.workflows], "workflows-reload"),
            (
                "repeated",
                [MaintenanceFrame.skills, MaintenanceFrame.workflows, MaintenanceFrame.skills, MaintenanceFrame.workflows],
                "skills-reload"
            ),
            ("outer-error", [MaintenanceFrame.outerError], "skills-reload"),
            ("opaque", [MaintenanceFrame.opaque], "workflows-reload")
        ]
        for testCase in cases {
            try await assertPromptTurnSurvives(
                label: testCase.label,
                frames: testCase.frames,
                maintenanceID: testCase.maintenanceID
            )
        }
    }

    func testMaintenanceReplyDuringBootstrapDoesNotFailSessionOpen() async throws {
        let label = "bootstrap"
        let harness = try makeHarness(label: label, phase: .bootstrap, frames: [MaintenanceFrame.skills])
        let controller = try harness.makeController()
        let events = await controller.currentEventsStream()
        do {
            let bootstrap = try await withHangBound(controller) { try await controller.bootstrap() }
            XCTAssertEqual(bootstrap.sessionID, "grok-maintenance-session", "\(label): unexpected session")
        } catch {
            XCTFail("\(label): session open failed: \(error.localizedDescription)")
            XCTAssertTrue(
                Self.isUnmatchedResponseFailure(error, id: "skills-reload"),
                "\(label): failed for a reason other than the unmatched skills-reload reply: \(error)"
            )
            await controller.shutdown()
            return
        }
        var promptError: (any Error)?
        do {
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "after bootstrap"), request: harness.request)
            }
        } catch {
            promptError = error
        }
        await controller.shutdown()
        XCTAssertNil(promptError, "\(label): prompt after session open failed: \(String(describing: promptError))")
        let drained = await drain(events)
        assertCompletedTurn(drained, content: ["second"], label: "\(label) prompt")
    }

    /// Proves the fixture: the same gated sequence without a maintenance reply completes both turns.
    func testNoMaintenanceControlCompletesTurn() async throws {
        try await assertPromptTurnSurvives(label: "no-maintenance", frames: [], maintenanceID: nil)
    }

    /// Other unmatched replies keep today's protocol-violation behavior. This encodes the
    /// recommended named-recognition policy: only the two known maintenance IDs are exempt,
    /// not every string ID the client never issued.
    func testUnknownStringIDStillProtocolViolation() async throws {
        let label = "other-reload"
        let harness = try makeHarness(label: label, phase: .prompt, frames: [MaintenanceFrame.unknownID])
        let controller = try harness.makeController()
        let events = await controller.currentEventsStream()
        do {
            _ = try await withHangBound(controller) { try await controller.bootstrap() }
        } catch {
            XCTFail("\(label): bootstrap failed before the prompt: \(error.localizedDescription)")
            await controller.shutdown()
            return
        }
        var promptError: (any Error)?
        do {
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "first"), request: harness.request)
            }
        } catch {
            promptError = error
        }
        await controller.shutdown()
        let drained = await drain(events)
        guard let promptError else {
            XCTFail("\(label): an unmatched string-ID reply must still fail the owned prompt")
            return
        }
        XCTAssertTrue(
            Self.isUnmatchedResponseFailure(promptError, id: "other-reload"),
            "\(label): failed for an unexpected reason: \(promptError)"
        )
        XCTAssertEqual(Self.content(in: drained).first, "prefix", "\(label): prompt never produced output")
        XCTAssertTrue(Self.terminals(in: drained).contains(.failed), "\(label): expected a failed terminal")
    }

    // MARK: - Scenario

    private func assertPromptTurnSurvives(label: String, frames: [String], maintenanceID: String?) async throws {
        let harness = try makeHarness(label: label, phase: .prompt, frames: frames)
        let controller = try harness.makeController()
        let turnOneEvents = await controller.currentEventsStream()
        do {
            _ = try await withHangBound(controller) { try await controller.bootstrap() }
        } catch {
            XCTFail("\(label): bootstrap failed before the prompt: \(error.localizedDescription)")
            await controller.shutdown()
            return
        }
        do {
            try await withHangBound(controller) {
                try await controller.prompt(AgentMessage(userMessage: "first"), request: harness.request)
            }
        } catch {
            XCTFail("\(label): owned prompt failed: \(error.localizedDescription)")
            if let maintenanceID {
                XCTAssertTrue(
                    Self.isUnmatchedResponseFailure(error, id: maintenanceID),
                    "\(label): failed for a reason other than the unmatched \(maintenanceID) reply: \(error)"
                )
            }
            await controller.shutdown()
            return
        }

        let promptsAfterTurnOne = harness.recordedMethods().count(where: { $0 == "session/prompt" })
        let reusable = await controller.prepareForNextTurn()
        var turnTwoEvents: AsyncStream<NormalizedAgentRuntimeEvent>?
        var turnTwoError: (any Error)?
        if reusable {
            turnTwoEvents = await controller.currentEventsStream()
            do {
                try await withHangBound(controller) {
                    try await controller.prompt(AgentMessage(userMessage: "second"), request: harness.request)
                }
            } catch {
                turnTwoError = error
            }
        }
        let methodsBeforeShutdown = harness.recordedMethods()
        await controller.shutdown()

        let turnOne = await drain(turnOneEvents)
        assertCompletedTurn(turnOne, content: ["prefix", "suffix"], label: "\(label) turn 1")
        XCTAssertEqual(promptsAfterTurnOne, 1, "\(label): owned prompt was not sent exactly once")
        XCTAssertTrue(reusable, "\(label): controller was not reusable after turn 1")
        XCTAssertNil(turnTwoError, "\(label): turn 2 failed: \(String(describing: turnTwoError))")
        if let turnTwoEvents {
            let turnTwo = await drain(turnTwoEvents)
            assertCompletedTurn(turnTwo, content: ["second"], label: "\(label) turn 2")
        }
        XCTAssertEqual(
            methodsBeforeShutdown.count(where: { $0 == "session/prompt" }),
            2,
            "\(label): unexpected session/prompt count across both turns"
        )
        XCTAssertFalse(
            methodsBeforeShutdown.contains("session/cancel"),
            "\(label): owned work was cancelled before shutdown"
        )
    }

    private func assertCompletedTurn(_ events: [NormalizedAgentRuntimeEvent], content expected: [String], label: String) {
        XCTAssertEqual(Self.content(in: events), expected, "\(label): owned output was lost or reordered")
        XCTAssertEqual(Self.terminals(in: events), [.completed], "\(label): expected exactly one completed terminal")
        let violations = events.compactMap { event -> String? in
            guard case let .stream(result) = event, let text = result.text, text.contains("unmatched ACP response id") else {
                return nil
            }
            return text
        }
        XCTAssertEqual(violations, [], "\(label): maintenance reply surfaced as a protocol violation")
        let stopIndex = events.firstIndex { Self.streamType(of: $0) == "message_stop" }
        let lastContentIndex = events.lastIndex { Self.streamType(of: $0) == "content" }
        XCTAssertNotNil(stopIndex, "\(label): turn produced no message_stop")
        if let stopIndex, let lastContentIndex {
            XCTAssertLessThan(lastContentIndex, stopIndex, "\(label): output arrived after the turn settled")
        }
    }

    private static func isUnmatchedResponseFailure(_ error: any Error, id: String) -> Bool {
        let text = error.localizedDescription
        return text.contains("unmatched ACP response id") && text.contains(id)
    }

    private static func streamType(of event: NormalizedAgentRuntimeEvent) -> String? {
        guard case let .stream(result) = event else { return nil }
        return result.type
    }

    private static func content(in events: [NormalizedAgentRuntimeEvent]) -> [String] {
        events.compactMap { event in
            guard case let .stream(result) = event, result.type == "content" else { return nil }
            return result.text
        }
    }

    private static func terminals(in events: [NormalizedAgentRuntimeEvent]) -> [AgentSessionRunState] {
        events.compactMap { event in
            guard case let .terminal(state, _) = event else { return nil }
            return state
        }
    }

    private func drain(_ stream: AsyncStream<NormalizedAgentRuntimeEvent>) async -> [NormalizedAgentRuntimeEvent] {
        var events: [NormalizedAgentRuntimeEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// A failure bound, not synchronization: `session/prompt` has no request timer, so a fixture
    /// or fix defect would otherwise hang the suite. Exceeds the 30 s bootstrap request tier twice.
    private func withHangBound<T>(
        _ controller: ACPAgentSessionController,
        _ operation: () async throws -> T
    ) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 90_000_000_000)
            await controller.shutdown()
        }
        defer { watchdog.cancel() }
        return try await operation()
    }

    // MARK: - Harness

    private enum Phase: String {
        case prompt
        case bootstrap
    }

    private enum MaintenanceFrame {
        static let skills = #"{"jsonrpc":"2.0","id":"skills-reload","result":{"result":{"reloaded":1}}}"#
        static let workflows = #"{"jsonrpc":"2.0","id":"workflows-reload","result":{"result":{"reloaded":1}}}"#
        static let outerError = #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":-32603,"message":"reload failed"}}"#
        static let opaque = #"{"jsonrpc":"2.0","id":"workflows-reload","result":null}"#
        static let unknownID = #"{"jsonrpc":"2.0","id":"other-reload","result":{}}"#
    }

    private struct Harness {
        let workspace: URL
        let recordURL: URL

        var request: ACPRunRequest {
            ACPRunRequest(
                agentKind: .grokBuild,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            )
        }

        func makeController() throws -> ACPAgentSessionController {
            let config = GrokBuildAgentConfig(
                commandName: workspace.appendingPathComponent("grok").path,
                additionalPathHints: [],
                modelString: nil,
                includeRepoPromptMCPServer: false
            )
            return try ACPAgentSessionController(provider: GrokBuildACPAgentProvider(config: config), runRequest: request)
        }

        /// Methods of the requests and notifications the fake received, in arrival order.
        func recordedMethods() -> [String] {
            guard let data = try? Data(contentsOf: recordURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    return nil
                }
                return object["method"] as? String
            }
        }
    }

    /// Writes the fake `grok` before the controller exists: launch identity is captured at init.
    private func makeHarness(label: String, phase: Phase, frames: [String]) throws -> Harness {
        let workspace = try makeTestDirectory(name: "GrokBuildACPMaintenance-\(label)")
        let recordURL = workspace.appendingPathComponent("received.jsonl")
        let scenario = try JSONSerialization.data(
            withJSONObject: ["phase": phase.rawValue, "frames": frames],
            options: [.withoutEscapingSlashes]
        )
        let recordPath = try JSONSerialization.data(
            withJSONObject: recordURL.path,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        let script = Self.fakeGrokScript
            .replacingOccurrences(of: "__SCENARIO_JSON__", with: String(decoding: scenario, as: UTF8.self))
            .replacingOccurrences(of: "__RECORD_PATH_JSON__", with: String(decoding: recordPath, as: UTF8.self))
        let scriptURL = workspace.appendingPathComponent("grok")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return Harness(workspace: workspace, recordURL: recordURL)
    }

    /// One dispatch loop: every inbound line is recorded, every request carrying an `id` is
    /// answered, and a held owned reply is released only when the barrier reply arrives.
    private static let fakeGrokScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    SCENARIO = json.loads(r'''__SCENARIO_JSON__''')
    RECORD_PATH = json.loads(r'''__RECORD_PATH_JSON__''')
    SESSION_ID = "grok-maintenance-session"
    BARRIER_ID = "barrier-1"
    SESSION_NEW_RESULT = {"sessionId": SESSION_ID, "models": {
        "currentModelId": "grok-4.6",
        "availableModels": [
            {"modelId": "grok-4.6", "name": "Grok 4.6"},
            {"modelId": "grok-4.5", "name": "Grok 4.5"}
        ]
    }}

    if "--help" in sys.argv:
        print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
        sys.exit(0)

    def record(entry):
        with open(RECORD_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")

    def write_line(text):
        try:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)

    def send(message):
        write_line(json.dumps(message))

    def respond(request_id, result):
        send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def chunk(text):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION_ID,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})

    def inject_maintenance_then_barrier():
        for frame in SCENARIO["frames"]:
            write_line(frame)
        send({"jsonrpc": "2.0", "id": BARRIER_ID, "method": "fake/barrier", "params": {}})

    held = None
    prompts = 0

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            record({"invalid": line[:200]})
            continue
        method = message.get("method")
        request_id = message.get("id")
        if method is None:
            record({"response": request_id})
            if request_id == BARRIER_ID and held is not None:
                kind, owned_id = held
                held = None
                if kind == "session/new":
                    respond(owned_id, SESSION_NEW_RESULT)
                else:
                    chunk("suffix")
                    respond(owned_id, {"stopReason": "end_turn"})
            continue
        record({"method": method, "id": request_id})
        if method == "initialize":
            respond(request_id, {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": True, "promptCapabilities": {"embeddedContext": True}},
                "authMethods": []
            })
        elif method == "session/new" and SCENARIO["phase"] == "bootstrap":
            held = ("session/new", request_id)
            inject_maintenance_then_barrier()
        elif method == "session/new":
            respond(request_id, SESSION_NEW_RESULT)
        elif method == "session/prompt":
            prompts += 1
            if prompts == 1 and SCENARIO["phase"] == "prompt":
                chunk("prefix")
                held = ("session/prompt", request_id)
                inject_maintenance_then_barrier()
            else:
                chunk("second")
                respond(request_id, {"stopReason": "end_turn"})
        elif request_id is not None:
            respond(request_id, {})
    """# + "\n"
}
