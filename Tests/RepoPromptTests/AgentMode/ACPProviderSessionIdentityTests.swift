import Foundation
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class ACPProviderSessionIdentityTests: XCTestCase {
    func testACPBootstrapRefusesDevinNewAndColdResumeWithoutFixtureOptIn() async throws {
        // Hydration can request a fresh controller for a persisted provider session;
        // neither that identity nor discovery is permission to start a provider in XCTest.
        for resumeID in [nil, "persisted-devin-session"] as [String?] {
            let workspace = try makeTemporaryDirectory()
            let recordURL = workspace.appendingPathComponent("requests.jsonl")
            let provider = try FakeACPProvider(
                providerID: .devin,
                commandPath: makeFakeACPServerScript().path,
                environment: ["ACP_RECORD_PATH": recordURL.path]
            )
            let request = makeRunRequest(agentKind: .devin, workspacePath: workspace.path, resumeSessionID: resumeID)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
            do {
                _ = try await controller.bootstrap()
                XCTFail("Discovery and cold resume must fail closed without an explicit fixture permit")
            } catch {
                XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
            }
            let identity = await controller.currentProviderSessionIdentity()
            XCTAssertNil(identity.runtimeSessionID)
            XCTAssertEqual(identity.loadSessionID, resumeID)
            await controller.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "Refusal must precede ACP initialization")
        }
    }

    func testCursorNewSessionPublishesRuntimeIDAsVerifiedLoadID() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = FakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: ["ACP_RUNTIME_SESSION_ID": "cursor-runtime-id"]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
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
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)

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
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)

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

    func testNegotiatedImagesRequireLiteralTrueAndRefusalKeepsTextUsable() async throws {
        for capability in ["{\"image\":true}", "{}", "{\"image\":false}", "{\"image\":null}", "{\"image\":1}", "{\"image\":\"true\"}", "[]", "{\"image\":0}"] {
            let workspace = try makeTemporaryDirectory()
            let record = workspace.appendingPathComponent("requests.jsonl")
            let builds = BuildObserver()
            let provider = try FakeACPProvider(
                providerID: .cursor,
                commandPath: makeFakeACPServerScript().path,
                environment: ["ACP_RECORD_PATH": record.path, "ACP_PROMPT_CAPABILITIES": capability, "ACP_COMMAND": "compact"],
                builds: builds
            )
            let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5), allowsProviderProcessLaunchForTesting: true)
            let bootstrap = try await controller.bootstrap()
            let image = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: nil)
            let supported = capability == "{\"image\":true}"
            do {
                try await controller.prompt(AgentMessage(userMessage: "image", transientImages: [image]))
                XCTAssertTrue(supported)
            } catch {
                XCTAssertFalse(supported)
                guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                    await controller.shutdown()
                    continue
                }
            }
            if !supported {
                let attachmentRequest = ACPRunRequest(
                    agentKind: .cursor,
                    modelString: nil,
                    workspacePath: workspace.path,
                    resumeSessionID: nil,
                    attachments: [AgentImageAttachment(source: .localFile(path: "/nonexistent-must-not-read.png"))],
                    taskLabelKind: nil
                )
                do {
                    try await controller.prompt(AgentMessage(userMessage: "attachment override"), request: attachmentRequest)
                    XCTFail("Effective override attachments must be gated")
                } catch {
                    guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                        await controller.shutdown()
                        continue
                    }
                }
            }
            XCTAssertEqual(builds.count, supported ? 1 : 0)
            let beforeText = recordedPrompts(at: record)
            XCTAssertEqual(beforeText.count, supported ? 1 : 0)
            if supported {
                let blocks = try XCTUnwrap(beforeText.first?["prompt"] as? [[String: Any]])
                XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "image"])
                XCTAssertEqual(blocks.last?["data"] as? String, "AQID")
                XCTAssertEqual(blocks.last?["mimeType"] as? String, "image/png")
            }
            try await controller.prompt(AgentMessage(userMessage: "next text"))
            XCTAssertEqual(recordedPrompts(at: record).count, supported ? 2 : 1)
            let deadline = Date().addingTimeInterval(5)
            while !controller.advertisesCommand("compact", inProviderSession: bootstrap.sessionID), Date() < deadline {
                await Task.yield()
            }
            XCTAssertTrue(controller.advertisesCommand("compact", inProviderSession: bootstrap.sessionID))
            let inheritedAttachments = ACPRunRequest(
                agentKind: .cursor,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [AgentImageAttachment(source: .localFile(path: "/must-not-read.png"))],
                taskLabelKind: nil
            )
            try await controller.promptAdvertisedCommand("compact", expectedSessionID: bootstrap.sessionID, request: inheritedAttachments)
            let commandBlocks = try XCTUnwrap(recordedPrompts(at: record).last?["prompt"] as? [[String: Any]])
            XCTAssertEqual(commandBlocks.count, 1)
            XCTAssertEqual(commandBlocks.first?["text"] as? String, "/compact")
            XCTAssertEqual(builds.count, supported ? 2 : 1)
            await controller.shutdown()
        }
    }

    func testInheritedAttachmentsRejectBeforeReadingAndTextOverrideRecovers() async throws {
        let workspace = try makeTemporaryDirectory()
        let record = workspace.appendingPathComponent("requests.jsonl")
        let builds = BuildObserver()
        let provider = try FakeACPProvider(
            providerID: .cursor,
            commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_RECORD_PATH": record.path],
            builds: builds
        )
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [AgentImageAttachment(source: .localFile(path: "/nonexistent-must-not-read.png"))],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        do {
            try await controller.prompt(AgentMessage(userMessage: "inherited attachment"))
            XCTFail("Expected local rejection")
        } catch {
            guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                await controller.shutdown()
                return
            }
        }
        XCTAssertEqual(builds.count, 0)
        XCTAssertTrue(recordedPrompts(at: record).isEmpty)
        try await controller.prompt(
            AgentMessage(userMessage: "text override"),
            request: makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        )
        XCTAssertEqual(builds.count, 1)
        XCTAssertEqual(recordedPrompts(at: record).count, 1)
        await controller.shutdown()
    }

    func testRealPromptRPCFailureStillRetiresController() async throws {
        let workspace = try makeTemporaryDirectory()
        let provider = try FakeACPProvider(
            providerID: .cursor,
            commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_FAIL_PROMPT": "1"]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .cursor, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        do { try await controller.prompt(AgentMessage(userMessage: "transport failure"))
            XCTFail("Expected RPC failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("real RPC failure"))
        }
        do { try await controller.prompt(AgentMessage(userMessage: "must not reuse"))
            XCTFail("Failed controller must refuse")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP controller expected sessionOpen or promptRunning, but was failed.")
        }
        await controller.shutdown()
    }

    private func recordedPrompts(at url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let object = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  object["method"] as? String == "session/prompt" else { return nil }
            return object["params"] as? [String: Any]
        }
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
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True, "promptCapabilities": json.loads(os.environ.get("ACP_PROMPT_CAPABILITIES", "{}"))}, "authMethods": []})
            elif method == "session/new":
                if os.environ.get("ACP_COMMAND"):
                    print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":runtime_session_id, "update":{"sessionUpdate":"available_commands_update", "availableCommands":[{"name":os.environ["ACP_COMMAND"], "description":"command"}]}}}), flush=True)
                respond(request.get("id"), {"sessionId": runtime_session_id})
            elif method == "session/load":
                session_id = params.get("sessionId")
                if fail_load:
                    message = load_error_message or ("session not found: " + str(session_id))
                    respond(request.get("id"), error={"code": load_error_code, "message": message})
                else:
                    respond(request.get("id"), {"sessionId": session_id})
            elif method == "session/prompt":
                if os.environ.get("ACP_FAIL_PROMPT"):
                    respond(request.get("id"), error={"code":-32603, "message":"real RPC failure"})
                    continue
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
    var builds: BuildObserver?

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
        builds?.increment()
        return try ACPPromptContentBuilder.blocks(text: message.userMessage, attachments: request.attachments, transientImages: message.transientImages)
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

private final class BuildObserver: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int {
        value.withLock { $0 }
    }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
