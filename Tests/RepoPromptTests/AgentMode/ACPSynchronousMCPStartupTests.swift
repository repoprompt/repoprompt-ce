import Foundation
@testable import RepoPrompt
import XCTest

final class ACPSynchronousMCPStartupTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testOpenCodeStyleSessionNewWaitsForMCPInitializeAndToolsList() async throws {
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("opencode-startup.jsonl")
        let acpScriptURL = try makeACPServerScript()
        let mcpScriptURL = try makeMCPServerScript()
        let request = makeRunRequest(agentKind: .openCode, workspacePath: workspace.path)
        let provider = SynchronousStartupFakeACPProvider(
            providerID: .openCode,
            commandPath: acpScriptURL.path,
            environment: [
                "ACP_STARTUP_STYLE": "opencode",
                "ACP_RECORD_PATH": recordURL.path
            ],
            mcpServer: RepoPromptMCPServerConfiguration(
                name: "RepoPromptFixture",
                command: mcpScriptURL.path
            )
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 2)
        )
        addTeardownBlock {
            await controller.shutdown()
        }

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "opencode-session")
        XCTAssertEqual(
            recordedEvents(at: recordURL),
            ["session_new_started", "mcp_initialize_completed", "mcp_tools_list_completed", "session_new_response"]
        )
    }

    func testCursorStyleSessionNewCatchesMissingMCPApprovalAndReturns() async throws {
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("cursor-startup.jsonl")
        let acpScriptURL = try makeACPServerScript()
        let mcpScriptURL = try makeMCPServerScript()
        let missingApprovalURL = workspace.appendingPathComponent("missing-mcp-approvals.json")
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = SynchronousStartupFakeACPProvider(
            providerID: .cursor,
            commandPath: acpScriptURL.path,
            environment: [
                "ACP_STARTUP_STYLE": "cursor",
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_CURSOR_APPROVAL_PATH": missingApprovalURL.path,
                "ACP_CURSOR_PROJECT_ROOT": workspace.path
            ],
            mcpServer: RepoPromptMCPServerConfiguration(
                name: "RepoPromptFixture",
                command: mcpScriptURL.path
            )
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 2)
        )
        addTeardownBlock {
            await controller.shutdown()
        }

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "cursor-session")
        XCTAssertEqual(
            recordedEvents(at: recordURL),
            ["session_new_started", "mcp_not_approved", "mcp_startup_failed", "session_new_response"]
        )
    }

    func testCursorStyleSessionNewStartsModernMCPServerWithLeasedApproval() async throws {
        let workspace = try makeTemporaryDirectory()
        let cursorDataDirectory = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("cursor-approved-startup.jsonl")
        let acpScriptURL = try makeACPServerScript()
        let mcpScriptURL = try makeMCPServerScript()
        let mcpConfiguration = RepoPromptMCPServerConfiguration(
            name: "RepoPromptFixture",
            command: mcpScriptURL.path
        )
        let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: workspace.path,
            cursorDataDirectory: cursorDataDirectory
        )
        let artifact = try XCTUnwrap(
            CursorIntegrationConfiguration.prepareProjectMCPApproval(
                workingDirectory: workspace.path,
                cursorDataDirectory: cursorDataDirectory,
                repoPromptMCPConfiguration: mcpConfiguration
            )
        )
        defer {
            CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)
        }
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = SynchronousStartupFakeACPProvider(
            providerID: .cursor,
            commandPath: acpScriptURL.path,
            environment: [
                "ACP_STARTUP_STYLE": "cursor",
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_CURSOR_APPROVAL_PATH": approvalURL.path,
                "ACP_CURSOR_PROJECT_ROOT": CursorIntegrationConfiguration.projectRootURL(
                    workingDirectory: workspace.path
                ).path
            ],
            mcpServer: mcpConfiguration,
            cleanupArtifact: artifact
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 2)
        )
        addTeardownBlock {
            await controller.shutdown()
        }

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "cursor-session")
        XCTAssertEqual(
            recordedEvents(at: recordURL),
            [
                "session_new_started",
                "mcp_approval_verified",
                "mcp_initialize_completed",
                "mcp_tools_list_completed",
                "session_new_response"
            ]
        )
    }

    private func makeRunRequest(agentKind: AgentProviderKind, workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPSynchronousMCPStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_synchronous_acp.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import hashlib
        import os
        import subprocess
        import sys

        style = os.environ.get("ACP_STARTUP_STYLE", "opencode")
        record_path = os.environ["ACP_RECORD_PATH"]

        def record(event):
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"event": event}) + "\n")

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        def start_mcp(server):
            env = os.environ.copy()
            for entry in server.get("env") or []:
                env[entry["name"]] = entry["value"]
            process = subprocess.Popen(
                [server["command"], *(server.get("args") or [])],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            try:
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": style, "version": "fixture"},
                    },
                }) + "\n")
                process.stdin.flush()
                if not process.stdout.readline():
                    raise RuntimeError("MCP initialize failed")
                record("mcp_initialize_completed")
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": {},
                }) + "\n")
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                    "params": {},
                }) + "\n")
                process.stdin.flush()
                if not process.stdout.readline():
                    raise RuntimeError("MCP tools/list failed")
                record("mcp_tools_list_completed")
            finally:
                if process.stdin:
                    process.stdin.close()
                process.terminate()
                process.wait(timeout=1)

        def require_cursor_approval(server):
            approval_path = os.environ.get("ACP_CURSOR_APPROVAL_PATH")
            project_root = os.environ.get("ACP_CURSOR_PROJECT_ROOT")
            if not approval_path or not project_root:
                return
            environment = {}
            for entry in server.get("env") or []:
                environment[entry["name"]] = entry["value"]
            server_config = {
                "command": server["command"],
                "args": [value for value in server.get("args") or [] if isinstance(value, str)],
                "env": environment,
            }
            payload = json.dumps(
                {"path": project_root, "server": server_config},
                separators=(",", ":"),
            )
            approval = (
                server["name"]
                + "-"
                + hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]
            )
            try:
                with open(approval_path, "r", encoding="utf-8") as handle:
                    approvals = json.load(handle)
            except Exception:
                approvals = []
            if approval not in approvals:
                record("mcp_not_approved")
                raise RuntimeError("MCP server has not been approved")
            record("mcp_approval_verified")

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": False}, "authMethods": []})
            elif method == "session/new":
                record("session_new_started")
                try:
                    server = (params.get("mcpServers") or [])[0]
                    if style == "cursor":
                        require_cursor_approval(server)
                    start_mcp(server)
                except Exception:
                    record("mcp_startup_failed")
                    if style == "opencode":
                        respond(request.get("id"), error={"code": -32000, "message": "MCP startup failed"})
                        continue
                record("session_new_response")
                respond(request.get("id"), {"sessionId": style + "-session"})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeMCPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_mcp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        if "--fail" in sys.argv:
            sys.exit(7)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            request_id = request.get("id")
            method = request.get("method")
            if request_id is None:
                continue
            if method == "initialize":
                result = {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "RepoPromptFixture", "version": "1"},
                }
            elif method == "tools/list":
                result = {"tools": [{
                    "name": "read_file",
                    "description": "fixture",
                    "inputSchema": {"type": "object", "properties": {}},
                }]}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func recordedEvents(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["event"] as? String
        }
    }
}

private struct SynchronousStartupFakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String
    let environment: [String: String]
    let mcpServer: RepoPromptMCPServerConfiguration
    var cleanupArtifact: ACPLaunchCleanupArtifact?

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
            enableDebugLogging: false,
            cleanupArtifact: cleanupArtifact
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: [mcpServer]
        )
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

    func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
        guard let artifact = configuration.cleanupArtifact,
              artifact.kind == CursorIntegrationConfiguration.cleanupArtifactKind
        else {
            return
        }
        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)
    }
}
