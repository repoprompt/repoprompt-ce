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

    func testDefaultOverridesMaterializeAppManagedComputerUseRuntimeServer() {
        let runtime = makeComputerUseRuntimeConfiguration(
            source: .appManagedBundledPlugin(
                mcpConfigPath: "/tmp/cua/.mcp.json",
                manifestPath: "/tmp/cua/.codex-plugin/plugin.json",
                version: "1.2.3"
            ),
            toolTimeoutSec: 456
        )

        let overrides = deterministicDefaultOverrides(
            computerUseEnabled: true,
            resolution: .resolved(runtime)
        )

        XCTAssertEqual(overrides["features.computer_use"] as? Bool, true)
        XCTAssertEqual(overrides["features.plugins"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.computer-use.enabled"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.computer-use.command"] as? String, "/tmp/cua/helper")
        XCTAssertEqual(overrides["mcp_servers.computer-use.args"] as? [String], ["mcp", "--stdio"])
        XCTAssertEqual(overrides["mcp_servers.computer-use.cwd"] as? String, "/tmp/cua")
        XCTAssertEqual(overrides["mcp_servers.computer-use.env"] as? [String: String], ["SKY_CUA_SERVICE_PATH": "/tmp/cua/service"])
        XCTAssertEqual(overrides["mcp_servers.computer-use.tool_timeout_sec"] as? Int, 456)
    }

    func testDefaultOverridesOnlyEnableAndTimeoutExplicitComputerUseMCP() {
        let runtime = makeComputerUseRuntimeConfiguration(
            source: .explicitMCPServer(configPath: "/tmp/.codex/config.toml"),
            toolTimeoutSec: nil
        )

        let overrides = deterministicDefaultOverrides(
            computerUseEnabled: true,
            resolution: .resolved(runtime)
        )

        XCTAssertEqual(overrides["mcp_servers.computer-use.enabled"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.computer-use.tool_timeout_sec"] as? Int, 10000)
        XCTAssertNil(overrides["mcp_servers.computer-use.command"])
        XCTAssertNil(overrides["mcp_servers.computer-use.args"])
        XCTAssertNil(overrides["mcp_servers.computer-use.cwd"])
        XCTAssertNil(overrides["mcp_servers.computer-use.env"])
    }

    func testDefaultOverridesSkipComputerUseRuntimeWhenDisabled() {
        let runtime = makeComputerUseRuntimeConfiguration(
            source: .appManagedBundledPlugin(mcpConfigPath: "/tmp/cua/.mcp.json", manifestPath: nil, version: nil),
            toolTimeoutSec: 456
        )

        let overrides = deterministicDefaultOverrides(
            computerUseEnabled: false,
            resolution: .resolved(runtime)
        )

        XCTAssertEqual(overrides["features.computer_use"] as? Bool, false)
        XCTAssertNil(overrides["mcp_servers.computer-use.enabled"])
        XCTAssertNil(overrides["mcp_servers.computer-use.command"])
        XCTAssertNil(overrides["mcp_servers.computer-use.args"])
        XCTAssertNil(overrides["mcp_servers.computer-use.cwd"])
        XCTAssertNil(overrides["mcp_servers.computer-use.env"])
        XCTAssertNil(overrides["mcp_servers.computer-use.tool_timeout_sec"])
    }

    func testDefaultOverridesSkipIncompleteComputerUseRuntimeResolution() {
        let overrides = deterministicDefaultOverrides(
            computerUseEnabled: true,
            resolution: .incomplete(.init(path: "/tmp/cua/.mcp.json", message: "missing command"))
        )

        XCTAssertEqual(overrides["features.computer_use"] as? Bool, true)
        XCTAssertNil(overrides["mcp_servers.computer-use.enabled"])
        XCTAssertNil(overrides["mcp_servers.computer-use.command"])
        XCTAssertNil(overrides["mcp_servers.computer-use.args"])
        XCTAssertNil(overrides["mcp_servers.computer-use.cwd"])
        XCTAssertNil(overrides["mcp_servers.computer-use.env"])
        XCTAssertNil(overrides["mcp_servers.computer-use.tool_timeout_sec"])
    }

    func testAgentModeDefaultDoesNotResolveComputerUseRuntimeWhenDisabled() async throws {
        var didResolveComputerUseRuntime = false
        let options = CodexNativeSessionController.Options.agentModeDefault(
            forceExperimentalSteering: true,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            computerUseEnabledProvider: { false },
            computerUseRuntimeConfigurationProvider: {
                didResolveComputerUseRuntime = true
                return .resolved(self.makeComputerUseRuntimeConfiguration(
                    source: .appManagedBundledPlugin(mcpConfigPath: "/tmp/cua/.mcp.json", manifestPath: nil, version: nil),
                    toolTimeoutSec: 456
                ))
            }
        )
        let (controller, recordURL) = try await makeController(options: options)

        _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        await controller.shutdown()

        XCTAssertFalse(didResolveComputerUseRuntime)
        let params = try recordedParams(for: "thread/start", at: recordURL)
        let config = try XCTUnwrap(params["config"] as? [String: Any])
        XCTAssertNil(config["mcp_servers.computer-use.command"])
        XCTAssertNil(config["mcp_servers.computer-use.args"])
        XCTAssertNil(config["mcp_servers.computer-use.cwd"])
        XCTAssertNil(config["mcp_servers.computer-use.env"])
        XCTAssertNil(config["mcp_servers.computer-use.tool_timeout_sec"])
    }

    private func deterministicDefaultOverrides(
        computerUseEnabled: Bool,
        resolution: CodexComputerUseRuntimeConfiguration.Resolution?
    ) -> [String: Any] {
        CodexNativeSessionController.defaultAppServerConfigOverrides(
            forceExperimentalSteering: false,
            approvalPolicy: .never,
            sandboxMode: .readOnly,
            approvalReviewer: .user,
            shellToolEnabled: false,
            goalSupportEnabled: false,
            computerUseEnabled: computerUseEnabled,
            computerUseRuntimeConfigurationResolution: resolution,
            serverEntries: [],
            preferences: .init(
                bashToolEnabled: false,
                searchToolEnabled: false,
                approvalPolicy: .never,
                sandboxMode: .readOnly,
                approvalReviewer: .user,
                enabledMCPServerNames: []
            )
        )
    }

    private func makeComputerUseRuntimeConfiguration(
        source: CodexComputerUseRuntimeConfiguration.Source,
        toolTimeoutSec: Int?
    ) -> CodexComputerUseRuntimeConfiguration {
        CodexComputerUseRuntimeConfiguration(
            serverName: "computer-use",
            command: "/tmp/cua/helper",
            args: ["mcp", "--stdio"],
            cwd: "/tmp/cua",
            env: ["SKY_CUA_SERVICE_PATH": "/tmp/cua/service"],
            enabled: nil,
            toolTimeoutSec: toolTimeoutSec,
            source: source
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
