import Foundation
@testable import RepoPromptApp
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
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .autoReview }
        )

        try await assertStartAndResumeGoalConfig(
            options: options,
            expectedGoalSupportEnabled: true,
            expectedApprovalReviewer: "auto_review"
        )
    }

    func testAgentModeDefaultCarriesExplicitGoalOptOutToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
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

    func testAgentModeDefaultCarriesReasoningSummaryOptInToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            goalSupportEnabledProvider: { true },
            reasoningSummariesEnabledProvider: { true }
        )

        try await assertStartAndResumeGoalConfig(
            options: options,
            expectedGoalSupportEnabled: true,
            expectedReasoningSummary: "auto"
        )
    }

    func testDefaultConfigOverridesOmitThreadReasoningSummaryWhenUnspecified() {
        let config = CodexNativeSessionController.defaultAppServerConfigOverrides()

        XCTAssertNil(config["model_reasoning_summary"])
        XCTAssertEqual(CodexAgentToolPreferences.ApprovalPolicy(storedValue: "on-failure"), .onRequest)
        XCTAssertEqual(CodexAgentToolPreferences.ApprovalReviewer.autoReview.appServerRequestValue, "auto_review")
    }

    func testDefaultAppServerClientLaunchOmitsProcessReasoningSummaryOverride() async throws {
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

        try await client.startIfNeeded()
        await client.stop()

        let arguments = try recordedProcessArguments(at: recordURL)
        XCTAssertTrue(arguments.contains("app-server"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("model_reasoning_summary=") })
    }

    func testExplicitAppServerClientLaunchSerializesProcessReasoningSummaryAuto() async throws {
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
                workingDirectory: directory.path,
                processModelReasoningSummary: .auto
            )
        )

        try await client.startIfNeeded()
        await client.stop()

        let arguments = try recordedProcessArguments(at: recordURL)
        XCTAssertTrue(arguments.contains("app-server"))
        XCTAssertTrue(arguments.contains("model_reasoning_summary=auto"))
    }

    func testNativeSessionControllerDefaultOptionsOmitProcessReasoningSummaryOverride() async throws {
        let options = CodexNativeSessionController.Options(
            requestTimeout: 5,
            configOverridesProvider: { [:] },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            authTokensRefreshHandler: nil
        )
        let (controller, recordURL) = try await makeController(options: options)

        _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        await controller.shutdown()

        try assertProcessLaunchOmitsReasoningSummaryOverride(at: recordURL, label: "default options process")
    }

    func testInitializedNotificationOmitsParams() async throws {
        let (controller, recordURL) = try await makeController(options: makeOptions())
        _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        await controller.shutdown()

        let initialized = try recordedRequest(for: "initialized", at: recordURL)
        XCTAssertEqual(initialized["hasParams"] as? Bool, false)
    }

    func testOptionalMemoryModeRetriesDoNotFailStartup() async throws {
        let options = CodexNativeSessionController.Options(
            requestTimeout: 0.2,
            configOverridesProvider: { [:] },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            authTokensRefreshHandler: nil
        )
        let (controller, recordURL) = try await makeController(
            options: options,
            ignoreMemoryModeRequests: true
        )

        let startedAt = Date()
        let ref = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(ref.conversationID, "fresh-thread")
        XCTAssertLessThan(elapsed, 30.0)
        let memoryModeRequests = try recordedRequests(for: "thread/memoryMode/set", at: recordURL)
        XCTAssertGreaterThanOrEqual(memoryModeRequests.count, 2)
        let memoryModeParams = try XCTUnwrap(memoryModeRequests.first?["params"] as? [String: Any])
        XCTAssertEqual(memoryModeParams["threadId"] as? String, "fresh-thread")
        XCTAssertEqual(memoryModeParams["mode"] as? String, "disabled")

        let requestCountAfterBackgroundRetry = try await waitForRecordedRequestCount(
            for: "thread/memoryMode/set",
            at: recordURL,
            minimumCount: 3
        )
        await controller.shutdown()
        XCTAssertGreaterThanOrEqual(requestCountAfterBackgroundRetry, 3)
    }

    func testResumeRequiresThreadIDAndIncludesOptionalPath() async throws {
        let (controller, recordURL) = try await makeController(options: makeOptions())
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "  existing-thread  ",
            rolloutPath: "/tmp/existing-thread.jsonl",
            model: nil,
            reasoningEffort: nil
        )

        _ = try await controller.startOrResume(existing: existing, baseInstructions: "Agent")
        await controller.shutdown()

        let params = try recordedParams(for: "thread/resume", at: recordURL)
        XCTAssertEqual(params["threadId"] as? String, "existing-thread")
        XCTAssertEqual(params["path"] as? String, "/tmp/existing-thread.jsonl")
    }

    func testResumeWithoutPathSendsRequiredThreadIDOnly() async throws {
        let (controller, recordURL) = try await makeController(options: makeOptions())
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )

        _ = try await controller.startOrResume(existing: existing, baseInstructions: "Agent")
        await controller.shutdown()

        let params = try recordedParams(for: "thread/resume", at: recordURL)
        XCTAssertEqual(params["threadId"] as? String, "existing-thread")
        XCTAssertNil(params["path"])
    }

    func testPathOnlyResumeFailsLocallyBeforeWritingRequest() async throws {
        let (controller, recordURL) = try await makeController(options: makeOptions())
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: " \n\t ",
            rolloutPath: "/tmp/path-only.jsonl",
            model: nil,
            reasoningEffort: nil
        )

        do {
            _ = try await controller.startOrResume(existing: existing, baseInstructions: "Agent")
            XCTFail("Expected path-only resume to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Cannot resume this Codex thread because its saved thread ID is missing. Start a new Codex thread instead."
            )
        }
        await controller.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testProtocolShapeRejectionsPreserveMessageAndAdviseCLIUpdate() {
        for method in ["initialize", "thread/resume"] {
            for code in [-32601, -32602] {
                let error = CodexAppServerClient.ClientError.requestFailed(
                    .init(method: method, code: code, message: "server rejected request", data: nil)
                )

                XCTAssertTrue(error.localizedDescription.hasPrefix("server rejected request"))
                XCTAssertTrue(error.localizedDescription.contains("Update the installed Codex CLI"))
                XCTAssertTrue(error.localizedDescription.contains(method))
            }
        }
    }

    func testUnrelatedRequestFailureDoesNotAddCLIUpdateHint() {
        let error = CodexAppServerClient.ClientError.requestFailed(
            .init(method: "turn/start", code: -32602, message: "turn rejected", data: nil)
        )

        XCTAssertEqual(error.localizedDescription, "turn rejected")
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
        expectedGoalSupportEnabled: Bool,
        expectedReasoningSummary: String = "none",
        expectedApprovalReviewer: String = "user"
    ) async throws {
        let (startController, startRecordURL) = try await makeController(options: options)
        _ = try await startController.startOrResume(existing: nil, baseInstructions: "Agent")
        await startController.shutdown()

        try assertGoalFeatureAndComputerUseConfig(
            in: recordedParams(for: "thread/start", at: startRecordURL),
            expectedGoalSupportEnabled: expectedGoalSupportEnabled,
            expectedReasoningSummary: expectedReasoningSummary,
            expectedApprovalReviewer: expectedApprovalReviewer,
            label: "thread/start"
        )
        try assertProcessLaunchOmitsReasoningSummaryOverride(at: startRecordURL, label: "thread/start process")
        try assertProcessLaunchOmitsDirectOnlyNamespaceOverride(at: startRecordURL, label: "thread/start process")

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
            expectedReasoningSummary: expectedReasoningSummary,
            expectedApprovalReviewer: expectedApprovalReviewer,
            label: "thread/resume"
        )
        try assertProcessLaunchOmitsReasoningSummaryOverride(at: resumeRecordURL, label: "thread/resume process")
        try assertProcessLaunchOmitsDirectOnlyNamespaceOverride(at: resumeRecordURL, label: "thread/resume process")
    }

    private func makeOptions() -> CodexNativeSessionController.Options {
        .agentModeDefault(
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user }
        )
    }

    private func makeController(
        options: CodexNativeSessionController.Options,
        ignoreMemoryModeRequests: Bool = false
    ) async throws -> (CodexNativeSessionController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(
            in: directory,
            recordURL: recordURL,
            ignoreMemoryModeRequests: ignoreMemoryModeRequests
        )
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

    private func makeFakeCodexAppServer(
        in directory: URL,
        recordURL: URL,
        ignoreMemoryModeRequests: Bool = false
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import sys

        record_path = \(String(reflecting: recordURL.path))
        ignore_memory_mode_requests = \(ignoreMemoryModeRequests ? "True" : "False")

        with open(record_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"method": "__process_args", "argv": sys.argv[1:]}) + "\\n")

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            has_params = "params" in request
            params = request.get("params") or {}
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "hasParams": has_params, "params": params}) + "\\n")
            if "id" not in request:
                continue
            if method == "thread/memoryMode/set" and ignore_memory_mode_requests:
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
        let request = try recordedRequest(for: method, at: recordURL)
        return try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func waitForRecordedRequestCount(
        for method: String,
        at recordURL: URL,
        minimumCount: Int,
        timeout: TimeInterval = 2
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var latestCount = try recordedRequests(for: method, at: recordURL).count
        while latestCount < minimumCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            latestCount = try recordedRequests(for: method, at: recordURL).count
        }
        return latestCount
    }

    private func recordedRequests(for method: String, at recordURL: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: recordURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var requests: [[String: Any]] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let lineData = try XCTUnwrap(String(line).data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            if object["method"] as? String == method {
                requests.append(object)
            }
        }
        return requests
    }

    private func recordedProcessArguments(at recordURL: URL) throws -> [String] {
        let request = try recordedRequest(for: "__process_args", at: recordURL)
        return try XCTUnwrap(request["argv"] as? [String])
    }

    private func recordedRequest(for method: String, at recordURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: recordURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let lineData = try XCTUnwrap(String(line).data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            if object["method"] as? String == method {
                return object
            }
        }
        XCTFail("No \(method) request was recorded")
        return [:]
    }

    private func assertGoalFeatureAndComputerUseConfig(
        in params: [String: Any],
        expectedGoalSupportEnabled: Bool,
        expectedReasoningSummary: String,
        expectedApprovalReviewer: String,
        label: String
    ) throws {
        XCTAssertEqual(params["approvalPolicy"] as? String, "never", label)
        XCTAssertEqual(params["sandbox"] as? String, "read-only", label)
        XCTAssertEqual(params["approvalsReviewer"] as? String, expectedApprovalReviewer, label)
        let config = try XCTUnwrap(params["config"] as? [String: Any], label)
        XCTAssertEqual(config["features.goals"] as? Bool, expectedGoalSupportEnabled, label)
        XCTAssertEqual(config["features.computer_use"] as? Bool, false, label)
        XCTAssertEqual(
            config["features.code_mode.direct_only_tool_namespaces"] as? [String],
            ["mcp__RepoPromptCE"],
            label
        )
        XCTAssertEqual(config["model_reasoning_summary"] as? String, expectedReasoningSummary, label)
        XCTAssertEqual(config["features.multi_agent"] as? Bool, false, label)
        XCTAssertNil(config["features.code_mode.enabled"], label)
        XCTAssertNil(config["approval_policy"], label)
        XCTAssertNil(config["sandbox_mode"], label)
        XCTAssertNil(config["approvals_reviewer"], label)
    }

    private func assertProcessLaunchOmitsReasoningSummaryOverride(at recordURL: URL, label: String) throws {
        let arguments = try recordedProcessArguments(at: recordURL)
        XCTAssertFalse(arguments.contains { $0.hasPrefix("model_reasoning_summary=") }, label)
    }

    private func assertProcessLaunchOmitsDirectOnlyNamespaceOverride(at recordURL: URL, label: String) throws {
        let arguments = try recordedProcessArguments(at: recordURL)
        XCTAssertFalse(
            arguments.contains { $0.hasPrefix("features.code_mode.direct_only_tool_namespaces=") },
            label
        )
    }
}
