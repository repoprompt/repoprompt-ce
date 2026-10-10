import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore
import XCTest

@MainActor
final class CodexIntegratedRunExecutionAdapterTests: XCTestCase {
    func testAcceptedDispatchOutcomesPreserveNativeResultAndClassifyAsTransientCompletion() async {
        let queueID = UUID()
        let outcomes: [CodexAgentModeCoordinator.NativeSendOutcome] = [
            .sent,
            .queuedFallback(queueID: queueID, reason: .activeWithoutAuthoritativeIdentity)
        ]

        for outcome in outcomes {
            var invocationCount = 0
            let result = await CodexIntegratedRunExecutionAdapter.execute {
                invocationCount += 1
                return outcome
            }

            XCTAssertEqual(invocationCount, 1)
            XCTAssertEqual(result.nativeOutcome, outcome)
            XCTAssertEqual(
                result.executionReport,
                DomainAgentRunExecutionReport(
                    result: .terminal(.completed(assistantText: nil)),
                    trace: [.executionStarted, .terminalOutcomeProduced(.completed)]
                )
            )
            XCTAssertEqual(result.didStartProviderRun, outcome == .sent)
            XCTAssertFalse(result.shouldReleaseCreatedOwnership)
        }
    }

    func testRejectedDispatchOutcomesPreserveMessageAndClassifyAsTransientFailure() async {
        let fixtures: [(CodexAgentModeCoordinator.NativeSendOutcome, String)] = [
            (.preDispatchRejected(message: "pre-dispatch rejected"), "pre-dispatch rejected"),
            (.failed(message: "provider failed"), "provider failed")
        ]

        for (outcome, message) in fixtures {
            let result = await CodexIntegratedRunExecutionAdapter.execute { outcome }

            XCTAssertEqual(result.nativeOutcome, outcome)
            XCTAssertEqual(
                result.executionReport,
                DomainAgentRunExecutionReport(
                    result: .terminal(.failed(assistantText: message, reason: .agentError)),
                    trace: [.executionStarted, .terminalOutcomeProduced(.failed)]
                )
            )
            XCTAssertFalse(result.didStartProviderRun)
            XCTAssertTrue(result.shouldReleaseCreatedOwnership)
        }
    }

    func testCancelledDispatchClassifiesAsCancellationWithoutLosingNativeResult() async {
        let result = await CodexIntegratedRunExecutionAdapter.execute { .cancelled }

        XCTAssertEqual(result.nativeOutcome, .cancelled)
        XCTAssertEqual(
            result.executionReport,
            DomainAgentRunExecutionReport(
                result: .terminal(.cancelled()),
                trace: [.executionStarted, .terminalOutcomeProduced(.cancelled)]
            )
        )
        XCTAssertFalse(result.didStartProviderRun)
        XCTAssertTrue(result.shouldReleaseCreatedOwnership)
    }

    func testStaleDispatchClassifiesAsNonterminalSupersession() async {
        let outcome = CodexAgentModeCoordinator.NativeSendOutcome.stale(reason: "run changed")
        let result = await CodexIntegratedRunExecutionAdapter.execute { outcome }

        XCTAssertEqual(result.nativeOutcome, outcome)
        XCTAssertEqual(
            result.executionReport,
            DomainAgentRunExecutionReport(
                result: .superseded,
                trace: [.executionStarted, .executionSuperseded]
            )
        )
        XCTAssertFalse(result.didStartProviderRun)
        XCTAssertTrue(result.shouldReleaseCreatedOwnership)
    }
}

@MainActor
final class CodexComputerUseWorkflowTests: XCTestCase {
    override func tearDown() {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        super.tearDown()
    }

    func testDefaultsOptInAndDisable() throws {
        let name = "computer-use-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
        CodexComputerUseWorkflow.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
        CodexComputerUseWorkflow.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
    }

    func testOwnedCompanionOverridesAndFailClosedOrdinaryTurns() throws {
        let key = "mcp_servers.\(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "computer-use"))"
        let saved = MCPIntegrationHelper.CodexServerEntry(rawName: "computer-use", normalizedName: "computer-use", cliPathComponent: MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "computer-use"))
        for (enabled, path) in [(false, Optional("/fake/SkyComputerUseClient")), (true, nil), (true, Optional("/fake/SkyComputerUseClient"))] {
            let overrides = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [saved], enabledMCPServerNames: ["computer-use"], suppressThirdPartyMCPServers: false, computerUseEnabled: enabled, computerUseClientPath: path)
            XCTAssertEqual(overrides["\(key).enabled"] as? Bool, false)
            XCTAssertNil(overrides[key])
        }
        let active = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [], enabledMCPServerNames: ["computer-use"], suppressThirdPartyMCPServers: true, computerUseEnabled: true, computerUseClientPath: "/fake/SkyComputerUseClient")
        let server = try XCTUnwrap(active[key] as? [String: Any])
        XCTAssertEqual(Set(server.keys), ["command", "args", "enabled"])
        XCTAssertEqual(server["command"] as? String, "/fake/SkyComputerUseClient")
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertEqual(server["enabled"] as? Bool, true)
        XCTAssertNil(active["\(key).enabled"])
        let ready = CodexNativeSessionController.defaultAppServerConfigOverrides(computerUseEnabled: true, computerUseClientPath: "/fake/SkyComputerUseClient", serverEntries: [])
        XCTAssertEqual(ready["features.computer_use"] as? Bool, true)
        XCTAssertEqual(ready["approval_policy"] as? String, "on-request")
        XCTAssertEqual(ready["approvals_reviewer"] as? String, "user")
        let unavailable = CodexNativeSessionController.defaultAppServerConfigOverrides(computerUseEnabled: true, computerUseClientPath: nil, serverEntries: [])
        XCTAssertEqual(unavailable["features.computer_use"] as? Bool, false)
    }

    func testControllerUsesUserReviewWithoutElevatingSandbox() async throws {
        for (enabled, path, expected) in [(true, Optional("/fake/SkyComputerUseClient"), CodexAgentToolPreferences.ApprovalPolicy.onRequest), (false, Optional("/fake/SkyComputerUseClient"), .never)] {
            let options = CodexNativeSessionController.Options.agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .readOnly }, approvalReviewerProvider: { .autoReview }, computerUseEnabledProvider: { enabled }, computerUseClientPathProvider: { path }, mcpServerEntriesProvider: { [] })
            let controller = makeController(options: options)
            let policy = try await controller.test_computerUseApprovalPolicy()
            XCTAssertEqual(policy.0, expected)
            XCTAssertEqual(policy.1, expected == .onRequest ? .user : .autoReview)
            XCTAssertEqual(options.sandboxModeProvider(), .readOnly)
            await controller.shutdown()
        }
    }

    func testElicitationUnderStricterPolicyIsEmittedNotAutoaccepted() async throws {
        for server in ["computer-use", "NotRepoPromptCE"] {
            var armed = true
            let controller = makeController(options: .agentModeDefault(approvalPolicyProvider: { .onRequest }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { armed }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }))
            _ = try await controller.test_computerUseApprovalPolicy()
            armed = false
            var events = controller.events.makeAsyncIterator()
            await controller.test_handleServerRequest(method: "mcpServer/elicitation/request", params: ["serverName": .string(server), "threadId": .string("thread"), "turnId": .string("turn"), "message": .string("Allow computer interaction?"), "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])])
            guard case let .mcpElicitationRequest(request) = await events.next() else {
                XCTFail("Expected a surfaced elicitation, not an automatic response")
                await controller.shutdown()
                continue
            }
            XCTAssertEqual(request.serverName, server)
            XCTAssertEqual(request.requestID, .int(42))
            await controller.shutdown()
        }
    }

    func testArmedElicitationAutoApprovalRequiresRepoPromptProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-codex")
        // Keep the bounded version probe independent of Python's cold startup. This test
        // exercises approval provenance, not external-runtime version detection.
        // Inert JSON-RPC peer: never Codex, never model/companion/TCC activity.
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf 'codex 0.160.1\\n'
            exit 0
        fi
        exec /usr/bin/python3 -u -c '
        import json, sys
        for line in sys.stdin:
            message = json.loads(line)
            if "method" in message and "id" in message:
                print(json.dumps({"id": message["id"], "result": {}}), flush=True)
        '
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let cases: [(Bool, String?, String, Bool, Bool, Bool)] = [
            (true, "RepoPromptCE", "apply_edits", true, true, false),
            (false, "RepoPromptCE", "apply_edits", true, true, false),
            (true, "computer-use", "apply_edits", true, true, false),
            (true, "computer-use", "apply_edits", false, true, true),
            (true, "computer-use", "apply_edits", false, false, false),
            (false, "computer-use", "apply_edits", false, true, false),
            (true, "computer-use", "mcp__OtherServer__apply_edits", false, true, false),
            (true, "NotRepoPromptCE", "mcp__RepoPromptCE__apply_edits", false, true, false),
            (true, nil, "apply_edits", false, true, false),
            (true, "RepoPromptCE", "mcp__OtherServer__apply_edits", false, true, false)
        ]
        for (enabled, server, tool, autoApproved, fullAccess, revoked) in cases {
            let recorder = MCPApprovalWireRecorder()
            let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            let client = CodexAppServerClient(
                writeFrameHandler: { descriptor, frame in
                    try FDWriteSupport.writeAll(frame, to: descriptor)
                    recorder.record(frame)
                },
                processEnvironmentBuilder: { _ in
                    ProcessEnvironmentResult(environment: environment, launchContext: .detect(from: environment), shellEnvironmentSource: .capturedLoginShell)
                }, runtimeStatePreparer: { _ in },
                launchSnapshot: .init(selection: .external(path: executable.path)), provisionsRepoPromptMCPOnStart: false
            )
            await client.updateProcessLaunchPolicy(featurePolicy: .defaultDisabled, modelReasoningSummary: nil)
            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await client.startIfNeeded() }
            var armed = enabled
            let controller = CodexNativeSessionController(client: client, runID: UUID(), tabID: UUID(), windowID: 1, workspacePaths: .uniform(nil), options: .agentModeDefault(approvalPolicyProvider: { fullAccess ? .never : .onRequest }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { armed }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }))
            _ = try await controller.test_computerUseApprovalPolicy()
            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await client.startIfNeeded() }
            armed = false
            if revoked { controller.revokeComputerUseAutoApproval() }
            var params: [String: CodexJSONValue] = ["toolName": .string(tool), "threadId": .string("thread"), "turnId": .string("turn"), "message": .string("Approve app tool call?"), "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])]
            if let server { params["serverName"] = .string(server) }
            await controller.test_handleServerRequest(method: "mcpServer/elicitation/request", params: params)
            var permissionParams = params
            permissionParams["itemId"] = .string("permission")
            permissionParams["cwd"] = .string(root.path)
            permissionParams["permissions"] = .object(["network": .object(["enabled": .bool(true)])])
            await controller.test_handleServerRequest(method: "item/permissions/requestApproval", params: permissionParams)
            let hostTypedAutoApproved = server == "RepoPromptCE" && autoApproved
            XCTAssertEqual(recorder.permissionScopes, autoApproved && !hostTypedAutoApproved ? ["turn"] : [], "Typed companion grants must follow the same policy without remembered consent")
            await controller.shutdown()
            if autoApproved {
                XCTAssertEqual(recorder.actions, hostTypedAutoApproved ? ["accept", "accept"] : ["accept"], "Genuine host typed permissions must match the unarmed base response while armed")
            } else {
                XCTAssertTrue(recorder.actions.isEmpty)
                var events = controller.events.makeAsyncIterator()
                guard case let .mcpElicitationRequest(request) = await events.next() else { return XCTFail("Unverified or companion request must be surfaced") }
                XCTAssertEqual(request.serverName, server)
                XCTAssertEqual(request.toolName, tool)
                guard case .permissionsRequest = await events.next() else { return XCTFail("Strict companion and unverified typed requests must surface") }
            }
        }
    }

    func testArmedStartupRetainsOnlyMCPElicitationCapability() async throws {
        let ordinaryCapabilities = CodexCapabilitySettings(appsEnabled: true, pluginsEnabled: true, mcpElicitationEnabled: false, toolSuggestionsEnabled: true)
        for armed in [true, false] {
            let options = CodexNativeSessionController.Options.agentModeDefault(
                approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess },
                approvalReviewerProvider: { .autoReview }, capabilitiesProvider: { ordinaryCapabilities },
                computerUseEnabledProvider: { armed }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" },
                mcpServerEntriesProvider: { [] }
            )
            let controller = makeController(options: options, requestExecutor: { _, _, _ in ["config": [:]] })
            let threadConfig = try await controller.test_computerUseStartupConfig()
            XCTAssertEqual(threadConfig["features.tool_call_mcp_elicitation"] as? Bool, armed)
            for key in ["features.apps", "features.plugins", "features.tool_suggest"] {
                XCTAssertEqual(threadConfig[key] as? Bool, !armed, key)
            }
            let policy = try await controller.test_computerUseApprovalPolicy()
            XCTAssertEqual(policy.0, armed ? .onRequest : .never)
            XCTAssertEqual(policy.1, armed ? .user : .autoReview)
            await controller.shutdown()
        }
    }

    func testArmedProductionElicitationEnvelopePreservesHostAndForeignConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-codex")
        // Inert wire peer: never a model, companion, or desktop operation. Reports actual launch
        // flags so the protocol-selection regression is checked alongside the decoded envelope.
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex 0.160.1\n'; exit 0; fi
        exec /usr/bin/python3 -u -c '
        import json, sys
        binding = {}
        for line in sys.stdin:
            message = json.loads(line)
            if "method" in message and "id" in message:
                method = message["method"]
                result = {}
                if method == "test/launchArgs": result = {"args": sys.argv[1:], "binding": binding}
                if method == "config/read": result = {"config": {}}
                if method in ("thread/start", "thread/resume"):
                    binding = message.get("params", {})
                    result = {"thread": {"id": "thread"}}
                print(json.dumps({"id": message["id"], "result": result}), flush=True)
        ' "$@"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for (server, fullAccess, accepted) in [("RepoPromptCE", true, true), ("computer-use", false, false), ("OtherServer", true, false), ("RepoPromptCE-lookalike", true, false)] {
            let recorder = MCPApprovalWireRecorder()
            let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            let client = CodexAppServerClient(
                writeFrameHandler: { descriptor, frame in
                    try FDWriteSupport.writeAll(frame, to: descriptor)
                    recorder.record(frame)
                },
                processEnvironmentBuilder: { _ in
                    ProcessEnvironmentResult(environment: environment, launchContext: .detect(from: environment), shellEnvironmentSource: .capturedLoginShell)
                }, runtimeStatePreparer: { _ in },
                launchSnapshot: .init(selection: .external(path: executable.path)), provisionsRepoPromptMCPOnStart: false
            )
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.runState = .running
            session.codexConversationID = "thread"
            session.beginRunAttempt(source: "production-elicitation-replay")
            let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .init(appsEnabled: false, pluginsEnabled: false, mcpElicitationEnabled: true, toolSuggestionsEnabled: false))
            let controller = CodexNativeSessionController(
                client: client, runID: runID, tabID: session.tabID, windowID: 1, workspacePaths: .uniform(nil),
                options: .agentModeDefault(approvalPolicyProvider: { fullAccess ? .never : .onRequest }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { true }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] })
            )
            session.codexController = controller
            addTeardownBlock { await controller.shutdown() }
            let existing = server == "RepoPromptCE" ? CodexNativeSessionController.SessionRef(conversationID: "thread", rolloutPath: nil, model: nil, reasoningEffort: nil) : nil
            _ = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                try await controller.startOrResume(existing: existing, baseInstructions: "")
            }
            let launch = try await client.request(method: "test/launchArgs", params: [:])
            let elicitationEnabled = (launch["args"] as? [String])?.contains("features.tool_call_mcp_elicitation=true") == true
            XCTAssertTrue(elicitationEnabled)
            let binding = try XCTUnwrap(launch["binding"] as? [String: Any])
            let threadConfig = try XCTUnwrap(binding["config"] as? [String: Any])
            XCTAssertEqual(threadConfig["features.tool_call_mcp_elicitation"] as? Bool, true)
            for key in ["features.apps", "features.plugins", "features.tool_suggest"] {
                XCTAssertEqual(threadConfig[key] as? Bool, false, key)
            }
            XCTAssertEqual(binding["approvalPolicy"] as? String, "on-request")
            XCTAssertEqual(binding["approvalsReviewer"] as? String, "user")
            let coordinator = makeCoordinator()
            let dispatch = Task {
                for await event in controller.events {
                    await coordinator.test_handleCodexNativeEvent(event, session: session, sourceController: controller)
                }
            }
            addTeardownBlock { @MainActor in
                await controller.shutdown()
                dispatch.cancel()
                await dispatch.value
            }
            // Pinned producer shape: serverName is top-level; form/message/schema are nested,
            // with no invented toolName. Wording is deliberately insufficient authority.
            let envelope: [String: Any] = [
                "id": 42, "method": "mcpServer/elicitation/request",
                "params": [
                    "serverName": server,
                    "threadId": "thread",
                    "turnId": "turn",
                    "request": [
                        "type": "form",
                        "message": "Allow RepoPromptCE MCP server to run apply_edits?",
                        "requestedSchema": ["type": "object", "properties": [:]],
                        "_meta": ["codex_approval_kind": "mcp_tool_call"]
                    ]
                ]
            ]
            // The pinned producer falls back to provenance-free questions when the launch flag is off.
            // Choose its wire shape from the actual process policy so the old host-card symptom fails here.
            let legacy: [String: Any] = [
                "id": 42, "method": "item/tool/requestUserInput",
                "params": [
                    "threadId": "thread", "turnId": "turn", "itemId": "approval",
                    "questions": [[
                        "id": "mcp_tool_call_approval_apply_edits", "header": "Approve app tool call?",
                        "question": "Allow RepoPromptCE MCP server to run apply_edits?",
                        "isOther": false, "isSecret": false,
                        "options": [
                            ["label": "Allow", "description": "One call"],
                            ["label": "Cancel", "description": "Refuse"]
                        ]
                    ]]
                ]
            ]
            try await client.debugIngestRawStdoutLine(JSONSerialization.data(withJSONObject: elicitationEnabled ? envelope : legacy))
            try await AsyncTestWait.waitUntil("production envelope decision for \(server)", timeout: 4) {
                recorder.actions == ["accept"] || session.pendingMCPElicitationRequest != nil || session.pendingUserInputRequest != nil
            }
            XCTAssertNil(session.pendingUserInputRequest, "Structured approvals must not become Agent Questions")
            XCTAssertNil(session.pendingApproval)
            if accepted {
                XCTAssertNil(session.pendingMCPElicitationRequest, "Host apply_edits must not show a card")
                XCTAssertEqual(recorder.actions, ["accept"])
            } else {
                XCTAssertEqual(session.pendingMCPElicitationRequest?.serverName, server)
                XCTAssertTrue(recorder.actions.isEmpty, "Foreign and strict companion approvals require user consent")
            }
            await controller.shutdown()
            await dispatch.value
        }
    }

    func testPermissionRequestIsSurfacedAndCannotBeRememberedOrSurviveTeardown() async throws {
        var armed = true
        let controller = makeController(options: .agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { armed }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }))
        _ = try await controller.test_computerUseApprovalPolicy()
        armed = false
        var events = controller.events.makeAsyncIterator()
        await controller.test_handleServerRequest(method: "item/permissions/requestApproval", params: ["threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("permission-item"), "cwd": .string("/tmp"), "reason": .string("Allow computer interaction?"), "permissions": .object(["network": .object(["enabled": .bool(true)])])])
        guard case let .permissionsRequest(request) = await events.next() else {
            XCTFail("Permission requests must reach the one-shot user UI")
            await controller.shutdown()
            return
        }
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.codexController = controller
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        session.pendingPermissionsRequest = request
        let coordinator = makeCoordinator()
        coordinator.submitPermissionsDecision(session: session, request: request, decision: .acceptForSession)
        XCTAssertEqual(session.pendingPermissionsRequest?.id, request.id, "Remembered approval must not be submitted")
        await coordinator.revokeCodexComputerUse(session: session, reason: "user-off")
        XCTAssertNil(session.pendingPermissionsRequest)
        XCTAssertNil(session.codexController)
        XCTAssertNil(session.codexControllerFeatureState)
    }

    func testMissingCompanionAndOrdinaryTurnNeverAdmit() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let (viewModel, session) = makeAdmissionFixture(ready: false)
        let ordinary = await makeCoordinator().test_computerUseForNextTurn(session: session)
        XCTAssertFalse(ordinary)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let missing = await viewModel.test_codexCoordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(missing)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        withExtendedLifetime(viewModel) {}
    }

    func testReservedCollisionFailsClosedWithoutMutatingSavedDefinition() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let (viewModel, session) = makeAdmissionFixture(collision: true)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let admitted = await viewModel.test_codexCoordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(admitted)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        let saved: [String: Any] = ["command": "/user/custom", "env": ["TOKEN": "not-a-secret-fixture"], "tools": ["click": ["approval_mode": "approve"]]]
        let effective: [String: Any] = ["config": ["mcp_servers": ["computer-use": saved]]]
        XCTAssertThrowsError(try CodexNativeSessionController.validateComputerUseConfiguration(effective))
        XCTAssertEqual((effective["config"] as? NSDictionary)?["mcp_servers"] as? NSDictionary, ["computer-use": saved] as NSDictionary)
        withExtendedLifetime(viewModel) {}
        XCTAssertNoThrow(try CodexNativeSessionController.validateComputerUseConfiguration(["config": [:]]))
        XCTAssertThrowsError(try CodexNativeSessionController.validateComputerUseConfiguration([:]))
    }

    func testProcessLaunchNeverCreatesTransportlessDisabledEntry() throws {
        XCTAssertEqual(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: false, serverEntries: []), [])
        let active = try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: true, serverEntries: [])
        XCTAssertEqual(active, ["-c", "approval_policy=\"on-request\"", "-c", "approvals_reviewer=\"user\""])
        let saved = MCPIntegrationHelper.CodexServerEntry(rawName: "computer-use", normalizedName: "computer-use", cliPathComponent: "computer-use")
        XCTAssertEqual(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: false, serverEntries: [saved]), ["-c", "mcp_servers.computer-use.enabled=false"])
        XCTAssertThrowsError(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: true, serverEntries: [saved]))
        let ordinary = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [], enabledMCPServerNames: [], suppressThirdPartyMCPServers: false, computerUseEnabled: false, computerUseClientPath: nil)
        XCTAssertFalse(ordinary.keys.contains { $0.contains("computer-use") })
    }

    private func makeController(options: CodexNativeSessionController.Options, requestExecutor: (@Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any])? = nil) -> CodexNativeSessionController {
        CodexNativeSessionController(client: CodexAppServerClient(), runID: UUID(), tabID: UUID(), windowID: 1, workspacePaths: .uniform(nil), options: options, requestExecutor: requestExecutor)
    }

    func testQA90UnarmedRuntimeRetainsOwnedReservedCompanionDisable() async throws {
        let entry = MCPIntegrationHelper.CodexServerEntry(rawName: "computer-use", normalizedName: "computer-use", cliPathComponent: "computer-use")
        var proposed = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [entry], enabledMCPServerNames: [], suppressThirdPartyMCPServers: false, computerUseEnabled: false, computerUseClientPath: nil)
        XCTAssertEqual(proposed["mcp_servers.computer-use.enabled"] as? Bool, false)
        // The ordinary config builder combines this unchanged MCP map with the disabled feature.
        proposed["features.computer_use"] = false
        let baseMap = CodexOverrides.appServerMCPServerMap(entries: [entry], policy: .enableSelected(enabledNormalizedNames: [], repoPromptNormalizedName: MCPIntegrationHelper.repoPromptMCPServerName, exceptBroken: []))
        XCTAssertEqual(baseMap["mcp_servers.computer-use.enabled"] as? Bool, false)
        var options = CodexNativeSessionController.Options.agentModeDefault(computerUseEnabledProvider: { false }, computerUseClientPathProvider: { nil }, mcpServerEntriesProvider: { [entry] })
        let supplied = proposed
        options.configOverridesProvider = { supplied }
        let requests = OffStartupRequestRecorder()
        let controller = makeController(options: options, requestExecutor: { method, _, _ in
            requests.record(method)
            throw CodexAppServerClient.ClientError.invalidResponse
        })
        let runtime = try await controller.test_computerUseStartupConfig()
        XCTAssertEqual(runtime["mcp_servers.computer-use.enabled"] as? Bool, false, "The final ordinary thread overlay must retain the known owned-entry disabling flag")
        XCTAssertEqual(runtime["features.computer_use"] as? Bool, false)
        XCTAssertNil(runtime["mcp_servers.computer-use"])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: runtime, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: supplied, options: [.sortedKeys]), "Unarmed runtime must preserve the supplied static overlay exactly")
        XCTAssertEqual(requests.methods, [], "Static overlay preservation must not require a configuration RPC")
        await controller.shutdown()
    }

    func testOrdinaryStartupDoesNotRequestComputerUseConfiguration() async throws {
        for optedIn in [false, true] {
            CodexComputerUseWorkflow.setEnabledForTesting(optedIn)
            let requests = OffStartupRequestRecorder()
            let controller = makeController(options: .agentModeDefault(computerUseEnabledProvider: { false }, mcpServerEntriesProvider: { [] }), requestExecutor: { method, _, _ in
                requests.record(method)
                throw CodexAppServerClient.ClientError.invalidResponse
            })
            do {
                let config = try await controller.test_computerUseStartupConfig()
                XCTAssertFalse(config.keys.contains { $0.contains("computer-use") })
                XCTAssertEqual(config["features.computer_use"] as? Bool, false)
            } catch {
                XCTFail("An ordinary unarmed startup must not depend on config/read: \(error)")
            }
            XCTAssertEqual(requests.methods, [], "OFF and opted-in-but-unarmed starts must not add a configuration RPC")
            await controller.shutdown()
        }
    }

    func testOrdinaryProcessLaunchDoesNotRereadOwnedComputerUseConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("off-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-codex")
        let marker = root.appendingPathComponent("spawned")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex 0.156.0'; exit 0; fi\nprintf spawned > '\(marker.path)'\nexit 42\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let configURL = CodexRuntimeAuthority.statePaths().codexHome.appendingPathComponent("config.toml")
        let original = try? Data(contentsOf: configURL)
        defer {
            if let original { try? original.write(to: configURL) }
            else { try? FileManager.default.removeItem(at: configURL) }
        }
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let client = CodexAppServerClient(
            processSpawnPreparation: { try Data([0xFF]).write(to: configURL) },
            processEnvironmentBuilder: { _ in
                ProcessEnvironmentResult(environment: environment, launchContext: .detect(from: environment), shellEnvironmentSource: .capturedLoginShell)
            },
            runtimeStatePreparer: { runtime in
                XCTAssertEqual(runtime.statePaths.codexHome, configURL.deletingLastPathComponent())
                try FileManager.default.createDirectory(at: runtime.statePaths.codexHome, withIntermediateDirectories: true)
            },
            launchSnapshot: .init(selection: .external(path: executable.path)),
            provisionsRepoPromptMCPOnStart: false
        )
        await client.updateProcessLaunchPolicy(featurePolicy: .defaultDisabled, modelReasoningSummary: nil)
        do {
            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await client.startIfNeeded() }
            XCTFail("The inert test executable exits instead of initializing a provider")
        } catch {
            // Reaching this inert executable, despite deliberately invalid post-preparation bytes,
            // distinguishes a launch with no added owned-config read from the current regression.
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Ordinary launch must reach spawn without the new UTF-8 config read")
            XCTAssertEqual(try Data(contentsOf: configURL), Data([0xFF]))
        }
        await client.stop()
    }

    func testArmedEffectiveLayerCollisionAtControllerBoundary() async throws {
        let controller = makeController(options: .agentModeDefault(computerUseEnabledProvider: { true }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }), requestExecutor: { method, params, _ in
            XCTAssertEqual(method, "config/read")
            XCTAssertEqual(params?["includeLayers"] as? Bool, false)
            // No owned-file entry: this represents trusted project/managed configuration.
            return ["config": ["mcp_servers": ["computer-use": ["command": "/configured/client", "enabled": true]]]]
        })
        do {
            _ = try await controller.test_computerUseStartupConfig()
            XCTFail("Armed scope must reject effective collisions")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("computer-use"))
        }
        await controller.shutdown()
    }

    func testReadinessCannotEnableCompanionAfterPermissivePolicyDecision() async throws {
        var pathReads = 0
        let options = CodexNativeSessionController.Options.agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess }, approvalReviewerProvider: { .autoReview }, computerUseEnabledProvider: { true }, computerUseClientPathProvider: {
            pathReads += 1
            return pathReads == 1 ? nil : "/fake/SkyComputerUseClient"
        }, mcpServerEntriesProvider: { [] })
        let controller = makeController(options: options, requestExecutor: { _, _, _ in ["config": [:]] })
        do {
            _ = try await controller.test_computerUseStartupConfig()
            XCTFail("Missing readiness must abort, never downgrade scope")
        } catch {
            XCTAssertEqual(pathReads, 1)
        }
        let policy = try await controller.test_computerUseApprovalPolicy()
        XCTAssertEqual(policy.0, .onRequest)
        XCTAssertEqual(policy.1, .user)
        let config = try await controller.test_computerUseStartupConfig()
        XCTAssertEqual((config["mcp_servers.computer-use"] as? [String: Any])?["command"] as? String, "/fake/SkyComputerUseClient")
        await controller.shutdown()

        var acceptedReads = 0
        let frozen = makeController(options: .agentModeDefault(computerUseEnabledProvider: { true }, computerUseClientPathProvider: {
            acceptedReads += 1
            return acceptedReads == 1 ? "/accepted/SkyComputerUseClient" : nil
        }, mcpServerEntriesProvider: { [] }), requestExecutor: { _, _, _ in ["config": [:]] })
        let frozenConfig = try await frozen.test_computerUseStartupConfig()
        XCTAssertEqual((frozenConfig["mcp_servers.computer-use"] as? [String: Any])?["command"] as? String, "/accepted/SkyComputerUseClient")
        XCTAssertEqual(frozenConfig["approval_policy"] as? String, "on-request")
        await frozen.shutdown()
    }

    func testRejectedExplicitTurnDoesNotStartOrdinaryController() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        await makeCoordinator().ensureCodexNativeSession(session: session)
        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.codexController)
        XCTAssertEqual(session.items.last?.kind, .error)
    }

    func testMissingNativeEndpointFailsClosedWithoutTestInjection() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let admitted = await makeCoordinator().test_computerUseForNextTurn(session: session)
        XCTAssertFalse(admitted)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
    }

    private func makeAdmissionFixture(ready: Bool = true, collision: Bool = false) -> (AgentModeViewModel, AgentTabSession) {
        let viewModel = AgentModeViewModel(
            testWindowID: 1, testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in fatalError("Admission must not launch") },
            testCodexComputerUseCompanionReady: { ready }, testCodexComputerUseReservedEntryExists: { collision }
        )
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        return (viewModel, session)
    }

    private func makeCoordinator(ready: Bool = true, collision: Bool = false) -> CodexAgentModeCoordinator {
        CodexAgentModeCoordinator(windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) }, codexControllerFactory: { _, _, _, _, _, _, _, _ in fatalError("Admission tests must not launch a controller") }, connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, shouldManageCodexTooling: false, computerUseCompanionReady: { ready }, computerUseReservedEntryExists: { collision }, codexHookApprovalSettings: GlobalSettingsStore.shared)
    }
}

private final class OffStartupRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ method: String) {
        lock.withLock { recorded.append(method) }
    }

    var methods: [String] {
        lock.withLock { recorded }
    }
}

private final class MCPApprovalWireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []
    private var recordedPermissionScopes: [String] = []

    func record(_ frame: Data) {
        guard let packet = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              packet["id"] as? Int == 42,
              let result = packet["result"] as? [String: Any] else { return }
        lock.withLock {
            if let action = result["action"] as? String { recordedActions.append(action) }
            if result["permissions"] != nil, let scope = result["scope"] as? String { recordedPermissionScopes.append(scope) }
        }
    }

    var permissionScopes: [String] {
        lock.withLock { recordedPermissionScopes }
    }

    var actions: [String] {
        lock.withLock { recordedActions }
    }
}
