import Foundation
@testable import RepoPromptApp
import XCTest

final class ACPProviderSessionIdentityTests: XCTestCase {
    func testCursorNewSessionPublishesRuntimeIDAsVerifiedLoadID() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = FakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: ["ACP_RUNTIME_SESSION_ID": "cursor-runtime-id"]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        let stream = await controller.currentEventsStream()

        let bootstrap = try await controller.bootstrap()
        XCTAssertEqual(bootstrap.sessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)

        try await controller.prompt(AgentMessage(userMessage: "Hello Cursor"), request: request)
        let messageStop = await firstMessageStop(in: stream)
        await controller.shutdown()

        XCTAssertEqual(messageStop?.providerSessionID, "cursor-runtime-id")
    }

    func testOpenCodeColdResumeUsesPersistedSessionIDForLoad() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let recordURL = try makeTemporaryDirectory().appendingPathComponent("record.jsonl")
        let request = makeRunRequest(
            agentKind: .openCode,
            workspacePath: workspace.path,
            resumeSessionID: "persisted-session-id"
        )
        let provider = FakeACPProvider(
            providerID: .openCode,
            commandPath: scriptURL.path,
            environment: ["ACP_RECORD_PATH": recordURL.path]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(recordedSessionLoadIDs(at: recordURL), ["persisted-session-id"])
    }

    func testGenericLoadFailureFallbackInvalidatesStaleResumeID() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let recordURL = try makeTemporaryDirectory().appendingPathComponent("record.jsonl")
        let request = makeRunRequest(
            agentKind: .cursor,
            workspacePath: workspace.path,
            resumeSessionID: "stale-session-id"
        )
        let provider = FakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: [
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_FAIL_LOAD": "1",
                "ACP_RUNTIME_SESSION_ID": "fresh-runtime-id"
            ]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure)
        XCTAssertEqual(bootstrap.invalidatedResumeSessionID, "stale-session-id")
        XCTAssertEqual(bootstrap.sessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(recordedSessionLoadIDs(at: recordURL), ["stale-session-id"])
    }

    func testProviderSessionIdentityNormalizesEmptyIDs() {
        let identity = ACPProviderSessionIdentity(
            providerID: .cursor,
            runtimeSessionID: " cursor-runtime-id ",
            loadSessionID: "  ",
            loadSessionIDConfidence: .verified
        )

        XCTAssertEqual(identity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertNil(identity.loadSessionID)
        XCTAssertEqual(identity.loadSessionIDConfidence, .unavailable)
    }

    private func makeRunRequest(
        agentKind: AgentProviderKind,
        workspacePath: String,
        resumeSessionID: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "ACPProviderSessionIdentityTests")
    }

    private func makeFakeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        runtime_session_id = os.environ.get("ACP_RUNTIME_SESSION_ID", "runtime-session-id")
        fail_load = os.environ.get("ACP_FAIL_LOAD") == "1"
        load_error_code = int(os.environ.get("ACP_LOAD_ERROR_CODE", "-32602"))
        load_error_message = os.environ.get("ACP_LOAD_ERROR_MESSAGE")

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            record(method, params)
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/new":
                respond(request.get("id"), {"sessionId": runtime_session_id})
            elif method == "session/load":
                session_id = params.get("sessionId")
                if fail_load:
                    message = load_error_message or ("session not found: " + str(session_id))
                    respond(request.get("id"), error={"code": load_error_code, "message": message})
                else:
                    respond(request.get("id"), {"sessionId": session_id})
            elif method == "session/prompt":
                respond(request.get("id"), {"stopReason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 2}})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func firstMessageStop(in stream: AsyncStream<NormalizedAgentRuntimeEvent>) async -> AIStreamResult? {
        for await event in stream {
            switch event {
            case let .stream(result) where result.type == "message_stop":
                return result
            case .terminal:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private func recordedSessionLoadIDs(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "session/load",
                  let params = object["params"] as? [String: Any]
            else {
                return nil
            }
            return params["sessionId"] as? String
        }
    }
}

private struct FakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String
    let environment: [String: String]

    func support(for request: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
