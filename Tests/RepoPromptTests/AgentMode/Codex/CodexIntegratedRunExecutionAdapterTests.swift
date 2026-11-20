import Foundation
import os
@testable import RepoPromptApp
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore
import Security
import XCTest

@MainActor
final class CodexIntegratedRunExecutionAdapterTests: XCTestCase {
    func testDeferredAuthRefreshAndErrorRepliesKeepIngressTransport() async throws {
        let frames = OSAllocatedUnfairLock(initialState: [Data]())
        let client = CodexAppServerClient(writeFrameHandler: { _, frame in frames.withLock { $0.append(frame) } })
        await client.debugInstallTestTransport()
        let generation = await client.debugTransportGeneration()
        var requests = await client.subscribeServerRequests().makeAsyncIterator()
        let incoming = Data("{\"id\":99,\"method\":\"account/chatgptAuthTokens/refresh\",\"params\":{}}\n".utf8)
        await client.debugIngestStdoutChunk(incoming, generation: generation)
        let originValue = await requests.next()
        let origin = try XCTUnwrap(originValue).receipt
        let entered = expectation(description: "refresh suspended")
        let release = AsyncStream<Void>.makeStream()
        var options = CodexNativeSessionController.Options.agentModeDefault()
        options.authTokensRefreshHandler = { _ in
            entered.fulfill()
            for await _ in release.stream {
                break
            }
            return .init(accessToken: "fixture-refreshed-token", chatgptAccountID: "fixture-account", chatgptPlanType: "fixture-plan")
        }
        let controller = CodexNativeSessionController(client: client, runID: UUID(), tabID: UUID(), windowID: -1, workspacePaths: .uniform(nil), options: options)
        let reply = Task {
            await controller.test_handleServerRequest(receipt: origin, method: "account/chatgptAuthTokens/refresh", params: ["reason": .string("unauthorized")])
        }
        await fulfillment(of: [entered], timeout: 3)
        await client.stop()
        await client.debugInstallTestTransport()
        let successorGeneration = await client.debugTransportGeneration()
        XCTAssertNotEqual(generation, successorGeneration)
        release.continuation.yield(())
        await reply.value
        release.continuation.finish()
        XCTAssertEqual(frames.withLock { $0.count }, 0, "Suspended auth may not send credentials to a replacement transport")
        await controller.test_handleServerRequest(receipt: origin, method: "unknown-fixture-method", params: [:])
        XCTAssertEqual(frames.withLock { $0.count }, 0, "Error replies use the same physical origin fence")

        var successors = await client.subscribeServerRequests().makeAsyncIterator()
        await client.debugIngestStdoutChunk(incoming, generation: successorGeneration)
        let successorValue = await successors.next()
        let successor = try XCTUnwrap(successorValue).receipt
        await controller.test_handleServerRequest(receipt: successor, method: "unknown-fixture-method", params: [:])
        XCTAssertEqual(frames.withLock { $0.count }, 1)
        controller.test_installThreadState(threadID: "replacement-thread", authoritativeTurnID: "reused-turn", routingTurnID: "reused-turn")
        do {
            _ = try await controller.interruptUserTurn(expectedThreadID: "original-thread", expectedTurnID: "reused-turn", answering: successor)
            XCTFail("A matching turn ID cannot redirect a reply's follow-up to another thread")
        } catch let error as CodexAppServerClient.ClientError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected thread refusal: \(error)") }
        } catch { XCTFail("Unexpected thread refusal: \(error)") }
        XCTAssertEqual(frames.withLock { $0.count }, 1)
        await controller.shutdown()
        var liveness = 0
        var failures = 0
        var issues = 0
        for await event in controller.events {
            switch event {
            case .livenessActivity: liveness += 1
            case .error: failures += 1
            case .serverRequestIssue: issues += 1
            default: break
            }
        }
        XCTAssertEqual(liveness, 1, "Preserve the existing auth interaction liveness position")
        XCTAssertEqual(failures, 0, "Stale-origin refusals must not terminalize the successor run")
        XCTAssertEqual(issues, 1, "Only the current error reply emits its settled issue")
    }

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

    func testRuntimeEligibilityDependsOnSignatureNotBuildModeOrProvenance() {
        // Same decision for packaged release, local production, debug and external paths.
        for path in ["/release/bin/codex", "/local-production/bin/codex", "/debug/bin/codex", "/local/codex"] {
            let executable = URL(fileURLWithPath: path)
            for trusted in [true, false] {
                let message = CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: executable) { url, requirement in
                    XCTAssertEqual(url, executable)
                    XCTAssertEqual(requirement, "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"")
                    return trusted
                }
                XCTAssertEqual(message, trusted ? nil : CodexComputerUseWorkflow.runtimeRequirementMessage)
            }
        }
        XCTAssertNotNil(CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: URL(fileURLWithPath: "/nonexistent/codex")))
    }

    func testAdmissionCoalescesAsyncChecksCachesSuccessAndRetriesOnlyExplicitly() async throws {
        var loads = 0
        var release: CheckedContinuation<String?, Never>?
        let probe = CodexComputerUseWorkflow.RuntimeAdmissionPreflight(load: {
            loads += 1
            if loads == 1 { return "transient version-probe failure" }
            return await withCheckedContinuation { continuation in
                release = continuation
            }
        })
        XCTAssertEqual(probe.cachedMessage, CodexComputerUseWorkflow.checkingRuntimeMessage)
        let failure = await probe.check()
        XCTAssertEqual(failure, "transient version-probe failure")
        XCTAssertEqual(probe.cachedMessage, failure)
        probe.startIfNeeded()
        XCTAssertEqual(loads, 1, "UI reads must not retry failed probes")
        let retry = Task { await probe.check() }
        try await AsyncTestWait.waitUntil("runtime admission reaches suspended check", timeout: 3) { release != nil }
        // MainActor remains responsive while the shared preflight is suspended.
        XCTAssertEqual(probe.cachedMessage, failure)
        var secondCallerEntered = false
        let coalesced = Task {
            secondCallerEntered = true
            return await probe.check()
        }
        try await AsyncTestWait.waitUntil("second MainActor caller enters the shared check", timeout: 3) { secondCallerEntered }
        XCTAssertEqual(loads, 2, "Both callers must share the still-suspended load")
        release?.resume(returning: nil)
        let retryMessage = await retry.value
        let coalescedMessage = await coalesced.value
        XCTAssertNil(retryMessage)
        XCTAssertNil(coalescedMessage)
        XCTAssertNil(probe.cachedMessage)
        let cached = await probe.check()
        XCTAssertNil(cached)
        XCTAssertEqual(loads, 2, "Successful admission must not repeatedly resolve or hash the runtime")
    }

    func testSetupRecheckRefreshesSuccessfulAdmissionAndPublishesRuntimeChanges() async {
        var loads = 0
        var runtimeMessage: String?
        let probe = CodexComputerUseWorkflow.RuntimeAdmissionPreflight {
            loads += 1
            return runtimeMessage
        }
        let initial = await probe.check()
        XCTAssertNil(initial)

        // The selected executable can be removed or re-signed without changing its path.
        runtimeMessage = CodexComputerUseWorkflow.runtimeRequirementMessage
        let cached = await probe.check()
        XCTAssertNil(cached)
        XCTAssertEqual(loads, 1, "Ordinary admission should still reuse successful checks")

        let changed = await probe.check(forceRefresh: true)
        XCTAssertEqual(changed, runtimeMessage)
        XCTAssertEqual(probe.cachedMessage, runtimeMessage)
        XCTAssertEqual(loads, 2, "Setup re-check must not reuse cached success")
        probe.startIfNeeded()
        XCTAssertEqual(loads, 2, "Synchronous UI reads must not trigger another probe")

        runtimeMessage = nil
        let repaired = await probe.check(forceRefresh: true)
        XCTAssertNil(repaired)
        XCTAssertNil(probe.cachedMessage)
        let admitted = await probe.check()
        XCTAssertNil(admitted)
        XCTAssertEqual(loads, 3, "A repaired runtime should be cached again")
    }

    func testSetupRechecksAndAdmissionSharePendingRefreshInsteadOfCachedSuccess() async throws {
        var loads = 0
        var release: CheckedContinuation<String?, Never>?
        let probe = CodexComputerUseWorkflow.RuntimeAdmissionPreflight {
            loads += 1
            if loads == 1 { return nil }
            return await withCheckedContinuation { release = $0 }
        }
        let initial = await probe.check()
        XCTAssertNil(initial)
        let refresh = Task { await probe.check(forceRefresh: true) }
        defer { release?.resume(returning: nil) }
        try await AsyncTestWait.waitUntil("setup refresh reaches suspended load", timeout: 3) { release != nil }

        var refreshCallerEntered = false
        let coalesced = Task {
            refreshCallerEntered = true
            return await probe.check(forceRefresh: true)
        }
        var admissionCallerEntered = false
        let admission = Task {
            admissionCallerEntered = true
            return await probe.check()
        }
        try await AsyncTestWait.waitUntil("both callers join the pending refresh", timeout: 3) {
            refreshCallerEntered && admissionCallerEntered
        }
        XCTAssertEqual(loads, 2, "Concurrent requests must share one signature probe")
        release?.resume(returning: CodexComputerUseWorkflow.runtimeRequirementMessage)
        release = nil

        let refreshed = await refresh.value
        let coalescedResult = await coalesced.value
        let admissionResult = await admission.value
        XCTAssertEqual(refreshed, CodexComputerUseWorkflow.runtimeRequirementMessage)
        XCTAssertEqual(coalescedResult, refreshed)
        XCTAssertEqual(admissionResult, refreshed, "Admission must not bypass an active refresh with stale success")
        XCTAssertEqual(probe.cachedMessage, refreshed)
        XCTAssertEqual(loads, 2)
    }

    func testPreflightUsesCapturedInterpreterEnvironmentAndChecksSignatureOffMain() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let node = bin.appendingPathComponent("node")
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex-cli 0.159.0'\n".write(to: node, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env node\n".write(to: codex, atomically: true, encoding: .utf8)
        for url in [node, codex] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let result = await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            await CodexComputerUseWorkflow.preflightRuntimeRequirement(
                inheritedEnvironment: ["HOME": bin.path, "PATH": "/usr/bin:/bin"],
                shellEnvironmentProvider: { _, _ in
                    CLIEnvironmentSnapshot(environment: ["HOME": bin.path, "PATH": bin.path], source: .capturedLoginShell)
                },
                launchSnapshot: .init(selection: .external(path: codex.path)),
                signatureProbe: { url in
                    XCTAssertFalse(Thread.isMainThread)
                    XCTAssertEqual(url, codex.resolvingSymlinksInPath())
                    return "signature-probe-reached"
                }
            )
        }
        XCTAssertEqual(result, "signature-probe-reached", "The version probe must find its interpreter through captured shell PATH")
    }

    func testOpenAISigningRequirementParses() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(CodexComputerUseWorkflow.openAISigningRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
    }

    func testCachedVendorExecutableSatisfiesRealSigningRequirementWhenOptedIn() async throws {
        guard let cacheRoot = ProcessInfo.processInfo.environment["REPOPROMPT_CODEX_CACHE_ROOT"] else {
            throw XCTSkip("Opt in by setting REPOPROMPT_CODEX_CACHE_ROOT to the cached .build/codex-runtime directory")
        }
        let target = try XCTUnwrap(CodexRuntimeAuthority.currentArchitectureTarget)
        let executable = URL(fileURLWithPath: cacheRoot).appendingPathComponent(CodexRuntimeAuthority.bundledVersion.description).appendingPathComponent(target).appendingPathComponent("bin/codex")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("No cached vendor executable at \(executable.path); this test never downloads or runs Codex")
        }
        let message = await Task.detached(priority: .utility) {
            CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: executable)
        }.value
        XCTAssertNil(message, "Cached official Codex must pass the production static-code validator")
    }

    func testRuntimeRequirementRejectsArmingEvenWithCompanionPresent() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let (viewModel, session) = makeAdmissionFixture()
        let message = CodexComputerUseWorkflow.runtimeRequirementMessage
        var controllerCreated = false
        let coordinator = CodexAgentModeCoordinator(
            windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { _, _, _, _, _, _, _, _, _ in
                controllerCreated = true
                XCTFail("Rejected runtime must not launch")
                return self.makeController(options: .agentModeDefault())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false,
            computerUseRuntimeUnavailableMessage: { message },
            computerUseCompanionReady: { true }, computerUseReservedEntryExists: { false },
            codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        viewModel.configureCodexRuntime(coordinator)
        XCTAssertEqual(coordinator.nativeSlashCommandAvailabilityMessage(.computerUse, argumentsText: "", session: session), message)
        let requestID = UUID()
        session.codexComputerUseArmingRequestID = requestID
        do {
            try await coordinator.armCodexComputerUse(session: session, requestID: requestID)
            XCTFail("Unverified Codex must be refused before arming")
        } catch {
            XCTAssertEqual(error.localizedDescription, message)
        }
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertNil(session.codexController)
        XCTAssertFalse(controllerCreated)
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
            await controller.test_handleServerRequest(receipt: .fixture(.int(42)), method: "mcpServer/elicitation/request", params: ["serverName": .string(server), "threadId": .string("thread"), "turnId": .string("turn"), "message": .string("Allow computer interaction?"), "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])])
            guard case let .mcpElicitationRequest(request) = await events.next() else {
                XCTFail("Expected a surfaced elicitation, not an automatic response")
                await controller.shutdown()
                continue
            }
            XCTAssertEqual(request.serverName, server)
            XCTAssertEqual(request.receipt.requestID, .int(42))
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
                computerUseRuntimeUnavailableMessage: { _ in nil },
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
            await controller.test_handleServerRequest(receipt: .fixture(.int(42), generation: client.debugTransportGeneration(), clientID: client.instanceID), method: "mcpServer/elicitation/request", params: params)
            var permissionParams = params
            permissionParams["itemId"] = .string("permission")
            permissionParams["cwd"] = .string(root.path)
            permissionParams["permissions"] = .object(["network": .object(["enabled": .bool(true)])])
            await controller.test_handleServerRequest(receipt: .fixture(.int(43), generation: client.debugTransportGeneration(), clientID: client.instanceID), method: "item/permissions/requestApproval", params: permissionParams)
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
                computerUseRuntimeUnavailableMessage: { _ in nil },
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
        await controller.test_handleServerRequest(receipt: .fixture(.int(42)), method: "item/permissions/requestApproval", params: ["threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("permission-item"), "cwd": .string("/tmp"), "reason": .string("Allow computer interaction?"), "permissions": .object(["network": .object(["enabled": .bool(true)])])])
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
        let writers = AgentSessionRuntimeStore()
        let scope = writers.makeScope()
        let sessionID = UUID()
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([session.tabID: session])
        guard case let .unique(writer) = scope.resolveWriter(sessionID: sessionID) else {
            return XCTFail("Expected exact permissions writer")
        }
        let command = try writer.admitCommand().get()
        let interactions = scope.interactions(routeID: 1, approvalStore: ApplyEditsApprovalStore())
        XCTAssertFalse(interactions.submitPermissionsDecision(command: command, requestID: request.id, decision: .acceptForSession))
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

    func testArmedSpawnRejectsUnverifiedResolvedExecutableBeforeLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-codex")
        let marker = root.appendingPathComponent("spawned")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex 0.159.0'; exit 0; fi\nprintf spawned > '\(marker.path)'\nexit 42\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let client = CodexAppServerClient(
            computerUseRuntimeUnavailableMessage: { url in
                XCTAssertEqual(url, executable)
                return CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: url, signatureValidator: { _, _ in false })
            },
            processEnvironmentBuilder: { _ in
                ProcessEnvironmentResult(environment: environment, launchContext: .detect(from: environment), shellEnvironmentSource: .capturedLoginShell)
            },
            runtimeStatePreparer: { _ in },
            launchSnapshot: .init(selection: .external(path: executable.path)),
            provisionsRepoPromptMCPOnStart: false
        )
        await client.updateProcessLaunchPolicy(featurePolicy: .resolved(goalsEnabled: false, memoriesEnabled: false, computerUseEnabled: true), modelReasoningSummary: nil)
        do {
            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await client.startIfNeeded() }
            XCTFail("Unverified executable must not start an armed app-server")
        } catch {
            XCTAssertEqual(error.localizedDescription, CodexComputerUseWorkflow.runtimeRequirementMessage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await client.stop()
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
            computerUseRuntimeUnavailableMessage: { _ in XCTFail("Unarmed starts must not probe Computer Use signatures")
                return nil
            },
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
        CodexAgentModeCoordinator(windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) }, codexControllerFactory: { _, _, _, _, _, _, _, _, _ in fatalError("Admission tests must not launch a controller") }, connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, shouldManageCodexTooling: false, computerUseRuntimeUnavailableMessage: { nil }, computerUseCompanionReady: { ready }, computerUseReservedEntryExists: { collision }, codexHookApprovalSettings: GlobalSettingsStore.shared)
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
              let requestID = packet["id"] as? Int,
              [42, 43].contains(requestID),
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

final class CodexContextWindowConfigurationTests: XCTestCase {
    func testPresetOverridesArePairedAndDefaultIsEmpty() {
        XCTAssertTrue(CodexContextWindowPreferences.overrides(.codexDefault).isEmpty)
        XCTAssertTrue(CodexContextWindowPreferences.cliArguments(.codexDefault).isEmpty)
        XCTAssertEqual(CodexContextWindowPreferences.cliArguments(.tokens1M), ["-c", "model_auto_compact_token_limit=900000", "-c", "model_context_window=1000000"])
        for (selection, window, compact) in [
            (CodexContextWindowPreferences.Selection.tokens500K, 500_000, 450_000),
            (.tokens800K, 800_000, 720_000),
            (.tokens1M, 1_000_000, 900_000)
        ] {
            let overrides = CodexContextWindowPreferences.overrides(selection)
            XCTAssertEqual(overrides["model_context_window"], window)
            XCTAssertEqual(overrides["model_auto_compact_token_limit"], compact)
            let appServer = CodexNativeSessionController.defaultAppServerConfigOverrides(serverEntries: [], contextWindowSelection: selection)
            XCTAssertEqual(appServer["model_context_window"] as? Int, window)
            XCTAssertEqual(appServer["model_auto_compact_token_limit"] as? Int, compact)
        }
        let defaults = CodexNativeSessionController.defaultAppServerConfigOverrides(serverEntries: [])
        XCTAssertNil(defaults["model_context_window"])
        XCTAssertNil(defaults["model_auto_compact_token_limit"])
    }

    func testSelectionOrderAndLabels() {
        let selections = CodexContextWindowPreferences.Selection.allCases
        XCTAssertEqual(selections.map(\.rawValue), ["default", "500000", "600000", "700000", "800000", "900000", "1000000"])
        XCTAssertEqual(selections.map(\.label), ["Codex default", "500K tokens", "600K tokens", "700K tokens", "800K tokens", "900K tokens", "1M tokens"])
    }

    func testLegacySelectionIsReadWithoutRewriting() throws {
        let name = "CodexContextWindowLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "codexContextWindowSelection"
        defaults.set("750000", forKey: key)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .tokens800K)
        XCTAssertEqual(defaults.string(forKey: key), "750000")
        defaults.set("unknown", forKey: key)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
        XCTAssertEqual(defaults.string(forKey: key), "unknown")
    }

    @MainActor
    func testBindingKeepsSelectionAcrossControllerReplacementButColdSessionUsesCurrent() {
        let session = AgentTabSession(tabID: UUID())
        XCTAssertEqual(session.codexContextWindowForBinding(current: .tokens500K), .tokens500K)
        XCTAssertEqual(session.codexContextWindowForBinding(current: .tokens1M), .tokens500K)
        let coldSession = AgentTabSession(tabID: UUID())
        XCTAssertEqual(coldSession.codexContextWindowForBinding(current: .tokens1M), .tokens1M)
    }

    func testSelectionPersistence() throws {
        let name = "CodexContextWindowConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
        CodexContextWindowPreferences.setSelection(.tokens1M, defaults: defaults)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .tokens1M)
        CodexContextWindowPreferences.setSelection(.codexDefault, defaults: defaults)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
    }
}
