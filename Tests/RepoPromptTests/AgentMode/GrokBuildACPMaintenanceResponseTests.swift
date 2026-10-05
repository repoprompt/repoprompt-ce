import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildACPMaintenanceResponseTests: XCTestCase {
    override func setUp() {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    /// One real-controller scenario checks that interleaved maintenance cannot fail the owned prompt.
    func testMaintenanceReplyDuringPromptLeavesTurnIntact() async throws {
        let workspace = try makeTestDirectory()
        let scriptURL = workspace.appendingPathComponent("grok")
        try Self.fakeGrokScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let config = GrokBuildAgentConfig(
            commandName: scriptURL.path,
            additionalPathHints: [],
            modelString: nil,
            includeRepoPromptMCPServer: false
        )
        let controller = try ACPAgentSessionController(
            provider: GrokBuildACPAgentProvider(config: config), runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )
        let stream = await controller.currentEventsStream()
        do {
            _ = try await controller.bootstrap()
            try await controller.prompt(AgentMessage(userMessage: "first"), request: request)
        } catch {
            await controller.shutdown()
            throw error
        }
        await controller.shutdown()
        var events: [NormalizedAgentRuntimeEvent] = []
        for await event in stream {
            events.append(event)
        }
        let results = events.compactMap { event -> AIStreamResult? in
            guard case let .stream(result) = event else { return nil }
            return result
        }
        XCTAssertEqual(results.filter { $0.type == "content" }.compactMap(\.text), ["prefix", "suffix"])
        XCTAssertEqual(results.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertFalse(results.contains { $0.type == "error" })
        let terminals = events.compactMap { event -> AgentSessionRunState? in
            guard case let .terminal(state, _) = event else { return nil }
            return state
        }
        XCTAssertEqual(terminals, [.completed])
    }

    func testMaintenanceRecognitionRequiresKnownStringIDAndNoMethod() throws {
        let rows: [(label: String, frame: String, recognized: Bool)] = [
            ("skills-result", #"{"jsonrpc":"2.0","id":"skills-reload","result":{}}"#, true),
            ("workflows-error", #"{"jsonrpc":"2.0","id":"workflows-reload","error":{"code":-32603,"message":"reload failed"}}"#, true),
            ("id-only", #"{"id":"skills-reload"}"#, true),
            ("missing-version", #"{"id":"workflows-reload","result":null}"#, true),
            ("wrong-version", #"{"jsonrpc":"1.0","id":"skills-reload","result":{}}"#, true),
            ("both-result-and-error", #"{"id":"skills-reload","result":null,"error":null}"#, true),
            ("malformed-error", #"{"jsonrpc":"2.0","id":"workflows-reload","error":"opaque"}"#, true),
            ("incomplete-error", #"{"jsonrpc":"2.0","id":"skills-reload","error":{"code":1.5}}"#, true),
            ("string-method", #"{"id":"skills-reload","method":"unknown"}"#, false),
            ("null-method", #"{"id":"workflows-reload","method":null}"#, false),
            ("numeric-method", #"{"id":"skills-reload","method":7}"#, false),
            ("unknown-id", #"{"id":"other-reload"}"#, false),
            ("case-id", #"{"id":"Skills-reload"}"#, false),
            ("suffix-id", #"{"id":"skills-reload-1"}"#, false),
            ("numeric-id", #"{"id":3}"#, false),
            ("boolean-id", #"{"id":true}"#, false),
            ("null-id", #"{"id":null}"#, false),
            ("missing-id", #"{"result":{}}"#, false)
        ]
        let providers: [(label: String, provider: any ACPAgentProvider, optedIn: Bool)] = [
            ("grok", GrokBuildACPAgentProvider(config: GrokBuildAgentConfig()), true),
            ("default-off", NonOptedInProvider(commandPath: "unused"), false),
            ("grok-identity-without-override", NonOptedInProvider(providerID: .grokBuild, commandPath: "unused"), false)
        ]
        for row in rows {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.frame.utf8)) as? [String: Any])
            for entry in providers {
                XCTAssertEqual(
                    ACPAgentSessionController.isRecognizedUnmatchedResponse(json, provider: entry.provider),
                    row.recognized && entry.optedIn,
                    "\(entry.label): \(row.label)"
                )
            }
        }
    }

    /// Deliberately does not inherit Grok's provider implementation or any future opt-in.
    private struct NonOptedInProvider: ACPAgentProvider {
        var providerID: ACPProviderID = .cursor
        let commandPath: String

        func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
            ACPLaunchConfiguration(
                providerID: providerID,
                command: commandPath,
                arguments: [],
                environment: [:],
                workingDirectory: request.workspacePath,
                additionalPathHints: [],
                enableDebugLogging: false
            )
        }

        func makeSessionConfiguration(
            for request: ACPRunRequest,
            mcpServer _: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            ACPSessionConfiguration(
                mode: .new,
                workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
                mcpServers: []
            )
        }

        func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
            [["type": "text", "text": message.userMessage]]
        }

        func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            GrokBuildACPEventNormalizer.normalize(payload)
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }

    /// The single stdin loop sends maintenance before the genuine prompt response; no gate or timer is needed.
    private static let fakeGrokScript = #"""
    #!/usr/bin/env python3
    import json
    import sys

    SESSION_ID = "grok-maintenance-session"

    if "--help" in sys.argv:
        print("Usage: grok agent [OPTIONS] [COMMAND]\n\nCommands:\n  stdio    Run the agent over stdio")
        sys.exit(0)

    def send(message):
        print(json.dumps(message), flush=True)

    def respond(request_id, result):
        send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def chunk(text):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION_ID,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            respond(request_id, {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []})
        elif method == "session/new":
            respond(request_id, {"sessionId": SESSION_ID, "models": {
                "currentModelId": "grok-4.6",
                "availableModels": [{"modelId": "grok-4.6", "name": "Grok 4.6"}]}})
        elif method == "session/prompt":
            chunk("prefix")
            send({"id": "skills-reload", "result": {"reloaded": 1}})
            send({"id": "workflows-reload", "error": "opaque"})
            chunk("suffix")
            respond(request_id, {"stopReason": "end_turn"})
        elif request_id is not None:
            respond(request_id, {})
    """# + "\n"
}
