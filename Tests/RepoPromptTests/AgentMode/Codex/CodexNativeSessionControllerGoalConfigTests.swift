import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerGoalConfigTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testAgentModeDefaultCarriesGoalFeatureConfigToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
            forceExperimentalSteering: false,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user }
        )

        try await assertStartAndResumeGoalConfig(
            options: options,
            expectedGoalSupportEnabled: true
        )
    }

    func testAgentModeDefaultCarriesExplicitGoalOptOutToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
            forceExperimentalSteering: false,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            goalSupportEnabledProvider: { false }
        )

        try await assertStartAndResumeGoalConfig(
            options: options,
            expectedGoalSupportEnabled: false
        )
    }

    func testAgentModeDefaultCarriesExplicitGoalOptInToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
            forceExperimentalSteering: false,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            goalSupportEnabledProvider: { true }
        )

        try await assertStartAndResumeGoalConfig(
            options: options,
            expectedGoalSupportEnabled: true
        )
    }

    func testSafeManagedMCPOverridesSuppressThirdPartyServers() {
        let repoPromptName = MCPIntegrationHelper.repoPromptMCPServerName
        let entries = [
            MCPIntegrationHelper.CodexServerEntry(
                rawName: repoPromptName,
                normalizedName: repoPromptName,
                cliPathComponent: repoPromptName
            ),
            MCPIntegrationHelper.CodexServerEntry(
                rawName: "external-tools",
                normalizedName: "external-tools",
                cliPathComponent: "external-tools"
            ),
            MCPIntegrationHelper.CodexServerEntry(
                rawName: "computer-use",
                normalizedName: "computer-use",
                cliPathComponent: "computer-use"
            )
        ]
        let enabledNames: Set<String> = [repoPromptName, "external-tools"]

        let safeManaged = CodexNativeSessionController.appServerMCPServerOverrides(
            serverEntries: entries,
            enabledMCPServerNames: enabledNames,
            suppressThirdPartyMCPServers: true,
            computerUseEnabled: false
        )
        XCTAssertEqual(safeManaged["mcp_servers.\(repoPromptName).enabled"] as? Bool, true)
        XCTAssertEqual(safeManaged["mcp_servers.external-tools.enabled"] as? Bool, false)
        XCTAssertEqual(safeManaged["mcp_servers.computer-use.enabled"] as? Bool, false)

        let safeManagedComputerUse = CodexNativeSessionController.appServerMCPServerOverrides(
            serverEntries: entries,
            enabledMCPServerNames: enabledNames,
            suppressThirdPartyMCPServers: true,
            computerUseEnabled: true
        )
        XCTAssertEqual(safeManagedComputerUse["mcp_servers.external-tools.enabled"] as? Bool, false)
        XCTAssertEqual(safeManagedComputerUse["mcp_servers.computer-use.enabled"] as? Bool, true)
    }

    private func assertStartAndResumeGoalConfig(
        options: CodexNativeSessionController.Options,
        expectedGoalSupportEnabled: Bool
    ) async throws {
        let (startController, startRecordURL) = try await makeController(options: options)
        _ = try await startController.startOrResume(existing: nil, baseInstructions: "Agent")
        await startController.shutdown()

        try assertGoalFeatureAndComputerUseConfig(
            in: recordedParams(for: "thread/start", at: startRecordURL),
            expectedGoalSupportEnabled: expectedGoalSupportEnabled,
            label: "thread/start"
        )

        let (resumeController, resumeRecordURL) = try await makeController(options: options)
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
        _ = try await resumeController.startOrResume(existing: existing, baseInstructions: "Agent")
        await resumeController.shutdown()

        try assertGoalFeatureAndComputerUseConfig(
            in: recordedParams(for: "thread/resume", at: resumeRecordURL),
            expectedGoalSupportEnabled: expectedGoalSupportEnabled,
            label: "thread/resume"
        )
    }

    private func makeController(
        options: CodexNativeSessionController.Options
    ) async throws -> (CodexNativeSessionController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL)
        let client = CodexAppServerClient()
        await client.updateConfig(
            CodexAppServerClient.Config(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                workingDirectory: directory.path
            )
        )

        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePath: directory.path,
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        return (controller, recordURL)
    }

    private func makeFakeCodexAppServer(in directory: URL, recordURL: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import sys

        record_path = \(String(reflecting: recordURL.path))

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\\n")
            if "id" not in request:
                continue
            if method == "thread/start":
                respond(request["id"], {"thread": {"id": "fresh-thread", "status": "idle", "turns": []}})
            elif method == "thread/resume":
                respond(request["id"], {"thread": {"id": params.get("threadId", "resumed-thread"), "status": "idle", "turns": []}})
            else:
                respond(request["id"], {})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func recordedParams(for method: String, at recordURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: recordURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let lineData = try XCTUnwrap(String(line).data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            if object["method"] as? String == method {
                return try XCTUnwrap(object["params"] as? [String: Any])
            }
        }
        XCTFail("No \(method) request was recorded")
        return [:]
    }

    private func assertGoalFeatureAndComputerUseConfig(
        in params: [String: Any],
        expectedGoalSupportEnabled: Bool,
        label: String
    ) throws {
        let config = try XCTUnwrap(params["config"] as? [String: Any], label)
        XCTAssertEqual(config["features.goals"] as? Bool, expectedGoalSupportEnabled, label)
        XCTAssertEqual(config["features.computer_use"] as? Bool, false, label)
    }
}
