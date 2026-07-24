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
                processLaunchDirectory: directory.path
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
                processLaunchDirectory: directory.path,
                processModelReasoningSummary: .auto
            )
        )

        try await client.startIfNeeded()
        await client.stop()

        let arguments = try recordedProcessArguments(at: recordURL)
        XCTAssertTrue(arguments.contains("app-server"))
        XCTAssertTrue(arguments.contains("model_reasoning_summary=auto"))
    }

    func testProcessLaunchDirectoryUpdateKeepsRunningTransportAndAppliesAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        let launchDirectoryA = directory.appendingPathComponent("launch-a", isDirectory: true)
        let launchDirectoryB = directory.appendingPathComponent("launch-b", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDirectoryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchDirectoryB, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL)
        let client = CodexAppServerClient()
        await client.updateConfig(
            CodexAppServerClient.Config(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                processLaunchDirectory: launchDirectoryA.path
            )
        )

        try await client.startIfNeeded()
        let initialProcessIDValue = await client.debugProcessID()
        let initialProcessID = try XCTUnwrap(initialProcessIDValue)
        let initialGeneration = await client.debugTransportGeneration()

        await client.updateProcessLaunchDirectory(launchDirectoryB.path)

        let updatedProcessID = await client.debugProcessID()
        let updatedGeneration = await client.debugTransportGeneration()
        let isRunningAfterDirectoryUpdate = await client.debugIsProcessRunning()
        XCTAssertEqual(updatedProcessID, initialProcessID)
        XCTAssertEqual(updatedGeneration, initialGeneration)
        XCTAssertTrue(isRunningAfterDirectoryUpdate)
        XCTAssertEqual(
            try recordedRequests(for: "__process_args", at: recordURL)
                .compactMap { $0["cwd"] as? String }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [launchDirectoryA.resolvingSymlinksInPath().path]
        )

        await client.stop()
        try await client.startIfNeeded()

        let restartedGeneration = await client.debugTransportGeneration()
        let isRunningAfterRestart = await client.debugIsProcessRunning()
        XCTAssertEqual(restartedGeneration, initialGeneration + 1)
        XCTAssertTrue(isRunningAfterRestart)
        XCTAssertEqual(
            try recordedRequests(for: "__process_args", at: recordURL)
                .compactMap { $0["cwd"] as? String }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [
                launchDirectoryA.resolvingSymlinksInPath().path,
                launchDirectoryB.resolvingSymlinksInPath().path
            ]
        )
        await client.stop()
    }

    func testProcessLaunchPolicyUpdateRestartsOnlyForEffectiveChanges() async throws {
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
                processLaunchDirectory: directory.path
            )
        )

        try await client.startIfNeeded()
        let initialProcessIDValue = await client.debugProcessID()
        let initialProcessID = try XCTUnwrap(initialProcessIDValue)
        let initialGeneration = await client.debugTransportGeneration()

        await client.updateProcessLaunchPolicy(
            featurePolicy: .defaultDisabled,
            modelReasoningSummary: nil
        )

        let unchangedProcessID = await client.debugProcessID()
        let unchangedGeneration = await client.debugTransportGeneration()
        let isRunningAfterUnchangedPolicy = await client.debugIsProcessRunning()
        let unchangedTerminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(unchangedProcessID, initialProcessID)
        XCTAssertEqual(unchangedGeneration, initialGeneration)
        XCTAssertTrue(isRunningAfterUnchangedPolicy)
        XCTAssertNil(unchangedTerminationReason)

        await client.updateProcessLaunchPolicy(
            featurePolicy: .enabledForGoals,
            modelReasoningSummary: nil
        )

        let isRunningAfterFeaturePolicyChange = await client.debugIsProcessRunning()
        let processIDAfterFeaturePolicyChange = await client.debugProcessID()
        let generationAfterFeaturePolicyChange = await client.debugTransportGeneration()
        let featurePolicyTerminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertFalse(isRunningAfterFeaturePolicyChange)
        XCTAssertNil(processIDAfterFeaturePolicyChange)
        XCTAssertEqual(generationAfterFeaturePolicyChange, initialGeneration)
        XCTAssertEqual(featurePolicyTerminationReason, .explicitStop)

        try await client.startIfNeeded()
        let restartedGeneration = await client.debugTransportGeneration()
        let isRunningAfterPolicyRestart = await client.debugIsProcessRunning()
        XCTAssertEqual(restartedGeneration, initialGeneration + 1)
        XCTAssertTrue(isRunningAfterPolicyRestart)

        await client.updateProcessLaunchPolicy(
            featurePolicy: .enabledForGoals,
            modelReasoningSummary: .detailed
        )

        let isRunningAfterReasoningSummaryChange = await client.debugIsProcessRunning()
        let processIDAfterReasoningSummaryChange = await client.debugProcessID()
        let generationAfterReasoningSummaryChange = await client.debugTransportGeneration()
        let reasoningSummaryTerminationReason = await client.debugLastTransportTerminationReason()
        XCTAssertFalse(isRunningAfterReasoningSummaryChange)
        XCTAssertNil(processIDAfterReasoningSummaryChange)
        XCTAssertEqual(generationAfterReasoningSummaryChange, restartedGeneration)
        XCTAssertEqual(reasoningSummaryTerminationReason, .explicitStop)
    }

    func testWorktreePathSeparationPreservesStartResumeTurnAndWorkspaceWriteProtocol() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        let logicalRoot = directory.appendingPathComponent("logical-root", isDirectory: true)
        let worktreeRoot = directory.appendingPathComponent("worktree-root", isDirectory: true)
        let initialLaunchSentinel = directory.appendingPathComponent("initial-launch-sentinel", isDirectory: true)
        try FileManager.default.createDirectory(at: logicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: initialLaunchSentinel, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL)
        let workspacePaths = CodexRuntimeWorkspacePaths.worktreeBound(
            logicalRootPath: logicalRoot.path,
            validatedWorktreeRootPath: worktreeRoot.path
        )
        let options = CodexNativeSessionController.Options.agentModeDefault(
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .workspaceWrite },
            approvalReviewerProvider: { .user }
        )

        let startController = await makeController(
            executableURL: executableURL,
            initialProcessLaunchDirectory: initialLaunchSentinel.path,
            workspacePaths: workspacePaths,
            options: options
        )
        addTeardownBlock {
            await startController.shutdown()
        }
        let started = try await startController.startOrResume(existing: nil, baseInstructions: "Agent")
        let startReceipt = try await startController.startUserTurn(
            text: "fresh turn",
            images: [],
            model: "fresh-model",
            reasoningEffort: "high",
            serviceTier: "fast"
        )
        await startController.shutdown()

        XCTAssertEqual(started.conversationID, "fresh-thread")
        XCTAssertEqual(startReceipt.provisionalSubmissionID, "turn-1")

        let resumeController = await makeController(
            executableURL: executableURL,
            initialProcessLaunchDirectory: initialLaunchSentinel.path,
            workspacePaths: workspacePaths,
            options: options
        )
        addTeardownBlock {
            await resumeController.shutdown()
        }
        let resumed = try await resumeController.startOrResume(
            existing: .init(
                conversationID: "existing-thread",
                rolloutPath: "/tmp/existing-thread.jsonl",
                model: nil,
                reasoningEffort: nil
            ),
            baseInstructions: "Agent"
        )
        let resumeReceipt = try await resumeController.startUserTurn(
            text: "resumed turn",
            images: [],
            model: "resume-model",
            reasoningEffort: "medium",
            serviceTier: nil
        )
        await resumeController.shutdown()

        XCTAssertEqual(resumed.conversationID, "existing-thread")
        XCTAssertEqual(resumeReceipt.provisionalSubmissionID, "turn-1")

        let processRecords = try recordedRequests(for: "__process_args", at: recordURL)
        XCTAssertEqual(processRecords.count, 2)
        XCTAssertEqual(
            processRecords.compactMap { $0["cwd"] as? String }.map(resolvedPath),
            [resolvedPath(logicalRoot.path), resolvedPath(logicalRoot.path)]
        )

        let startParams = try recordedParams(for: "thread/start", at: recordURL)
        XCTAssertEqual(startParams["cwd"] as? String, worktreeRoot.path)
        let resumeParams = try recordedParams(for: "thread/resume", at: recordURL)
        XCTAssertEqual(resumeParams["cwd"] as? String, worktreeRoot.path)
        XCTAssertEqual(resumeParams["threadId"] as? String, "existing-thread")
        XCTAssertEqual(resumeParams["path"] as? String, "/tmp/existing-thread.jsonl")

        let turnParams = try recordedRequests(for: "turn/start", at: recordURL)
            .map { try XCTUnwrap($0["params"] as? [String: Any]) }
        XCTAssertEqual(turnParams.count, 2)
        XCTAssertEqual(turnParams.compactMap { $0["threadId"] as? String }, ["fresh-thread", "existing-thread"])
        XCTAssertEqual(turnParams.compactMap { $0["cwd"] as? String }, [worktreeRoot.path, worktreeRoot.path])
        XCTAssertEqual(turnParams.compactMap { $0["model"] as? String }, ["fresh-model", "resume-model"])
        XCTAssertEqual(turnParams.compactMap { $0["effort"] as? String }, ["high", "medium"])
        for params in turnParams {
            let sandbox = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
            XCTAssertEqual(sandbox["type"] as? String, "workspaceWrite")
            XCTAssertEqual(sandbox["networkAccess"] as? Bool, true)
            XCTAssertEqual(sandbox["writableRoots"] as? [String], [worktreeRoot.path])
        }
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

    func testLifecyclePhaseDiagnosticsUseFixedRedactedFieldsAcrossSuccessAndProvisioningFailure() async throws {
        let sensitiveSentinel = "SECRET_PATH_PROMPT_TOKEN_AUTH_URL_STDERR_RAW_ERROR"
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        AgentModePerfDiagnostics.clearRecentMetrics()
        addTeardownBlock {
            AgentModePerfDiagnostics.clearRecentMetrics()
            AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(nil)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLifecycleDiagnostics-\(sensitiveSentinel)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL)
        let registrar = CodexAppServerClient.ExpectedAgentPIDRegistrar(
            register: { _, _, _ in },
            clear: { _, _, _ in }
        )

        let client = CodexAppServerClient(
            provisionsRepoPromptMCPOnStart: false,
            expectedAgentPIDRegistrar: registrar
        )
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            processLaunchDirectory: directory.path
        ))
        var options = makeOptions()
        options.requestTimeout = 2
        options.repoPromptMCPProvisioner = { _ in }
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: sensitiveSentinel
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(
            existing: nil,
            baseInstructions: sensitiveSentinel
        )
        _ = try await controller.startUserTurn(
            text: sensitiveSentinel,
            images: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
        await controller.shutdown()

        let resumeClient = CodexAppServerClient(
            provisionsRepoPromptMCPOnStart: false,
            expectedAgentPIDRegistrar: registrar
        )
        await resumeClient.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            processLaunchDirectory: directory.path
        ))
        let resumeController = CodexNativeSessionController(
            client: resumeClient,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: sensitiveSentinel
        )
        addTeardownBlock { await resumeController.shutdown() }
        _ = try await resumeController.startOrResume(
            existing: .init(
                conversationID: "fresh-thread",
                rolloutPath: nil,
                model: nil,
                reasoningEffort: nil
            ),
            baseInstructions: sensitiveSentinel
        )
        await resumeController.shutdown()

        let successLines = AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 200)
            .filter { $0.contains("provider.codex.lifecycle.phase") }
        let expectedSuccessPhaseCounts = [
            "runtime_resolution": 2,
            "provisioning": 2,
            "spawn_initialize": 2,
            "thread_start": 1,
            "thread_resume": 1,
            "turn_acceptance": 1,
            "shutdown": 2
        ]
        XCTAssertEqual(successLines.count, expectedSuccessPhaseCounts.values.reduce(0, +))
        for (phase, expectedCount) in expectedSuccessPhaseCounts {
            let lines = successLines.filter { $0.contains("phase=\(phase)") }
            XCTAssertEqual(lines.count, expectedCount, phase)
            for line in lines {
                XCTAssertTrue(line.contains("duration="), phase)
                XCTAssertTrue(line.contains("outcome=succeeded"), phase)
                XCTAssertTrue(line.contains("tabID="), phase)
                XCTAssertFalse(line.contains(sensitiveSentinel), phase)
                XCTAssertFalse(line.contains("fresh-thread"), phase)
                XCTAssertFalse(line.contains("turn-1"), phase)
            }
        }
        for phase in ["spawn_initialize", "thread_start", "thread_resume", "turn_acceptance", "shutdown"] {
            let lines = successLines.filter { $0.contains("phase=\(phase)") }
            XCTAssertFalse(lines.isEmpty, phase)
            XCTAssertTrue(lines.allSatisfy { $0.contains("transportGeneration=1") }, phase)
        }
        for phase in ["runtime_resolution", "provisioning"] {
            let lines = successLines.filter { $0.contains("phase=\(phase)") }
            XCTAssertFalse(lines.isEmpty, phase)
            XCTAssertTrue(lines.allSatisfy { !$0.contains("transportGeneration=") }, phase)
        }

        AgentModePerfDiagnostics.clearRecentMetrics()
        let failingClient = CodexAppServerClient(
            provisionsRepoPromptMCPOnStart: false,
            expectedAgentPIDRegistrar: registrar
        )
        await failingClient.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            processLaunchDirectory: directory.path
        ))
        var failingOptions = makeOptions()
        failingOptions.requestTimeout = 2
        failingOptions.repoPromptMCPProvisioner = { _ in
            throw NSError(
                domain: sensitiveSentinel,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: sensitiveSentinel]
            )
        }
        let failingController = CodexNativeSessionController(
            client: failingClient,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: failingOptions,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: sensitiveSentinel
        )
        addTeardownBlock { await failingController.shutdown() }

        do {
            _ = try await failingController.startOrResume(
                existing: nil,
                baseInstructions: sensitiveSentinel
            )
            XCTFail("Provisioning must fail before process launch")
        } catch {
            XCTAssertEqual(error.localizedDescription, sensitiveSentinel)
        }

        let failureLines = AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 200)
            .filter { $0.contains("provider.codex.lifecycle.phase") }
        XCTAssertEqual(failureLines.count, 2)
        let provisioningFailure = try XCTUnwrap(failureLines.first { $0.contains("phase=provisioning") })
        XCTAssertTrue(provisioningFailure.contains("duration="))
        XCTAssertTrue(provisioningFailure.contains("outcome=failed"))
        XCTAssertFalse(provisioningFailure.contains("transportGeneration="))
        XCTAssertFalse(failureLines.joined(separator: "\n").contains(sensitiveSentinel))
        let failingProcessIsRunning = await failingClient.debugIsProcessRunning()
        XCTAssertFalse(failingProcessIsRunning)
    }

    func testControllerOptionBoundsSilentInitializeAndPoisonsExactTransportGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(
            in: directory,
            recordURL: recordURL,
            ignoreInitializeRequests: true
        )
        let client = CodexAppServerClient()
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: nil,
            processLaunchDirectory: directory.path
        ))
        var options = makeOptions()
        options.requestTimeout = 0.2
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        addTeardownBlock { await controller.shutdown() }

        let startup = Task {
            try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        }
        let cancellationSafety = Task {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            startup.cancel()
        }
        defer { cancellationSafety.cancel() }

        let didRecordInitialize = try await waitForRecordedRequestCount(
            for: "initialize",
            at: recordURL,
            minimumCount: 1
        ) == 1
        XCTAssertTrue(didRecordInitialize)
        let timedOutGeneration = await client.debugTransportGeneration()

        do {
            _ = try await startup.value
            XCTFail("The silent initialize request must time out")
        } catch let CodexAppServerClient.ClientError.requestFailed(failure) {
            XCTAssertEqual(failure.method, "initialize")
            XCTAssertTrue(failure.message.contains("timed out"))
        } catch is CancellationError {
            XCTFail("The controller option did not bound silent initialize")
        } catch {
            XCTFail("Expected initialize timeout, got \(error)")
        }

        let finalGeneration = await client.debugTransportGeneration()
        XCTAssertEqual(finalGeneration, timedOutGeneration)
        XCTAssertEqual(try recordedRequests(for: "initialize", at: recordURL).count, 1)
        guard case .timeout(method: "initialize", requestID: _) = await client.debugLastTransportTerminationReason() else {
            return XCTFail("Silent initialize did not poison its exact transport generation")
        }
    }

    func testControllerDefaultTimeoutDoesNotScheduleTurnStartDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(
            in: directory,
            recordURL: recordURL,
            ignoreTurnStartRequests: true
        )
        let client = CodexAppServerClient()
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: nil,
            processLaunchDirectory: directory.path
        ))
        var options = makeOptions()
        options.requestTimeout = 0.2
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        addTeardownBlock { await controller.shutdown() }

        _ = try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
        let turnStart = Task {
            try await controller.startUserTurn(
                text: "Do not duplicate this turn",
                images: [],
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
        }
        let didRecordTurnStart = try await waitForRecordedRequestCount(
            for: "turn/start",
            at: recordURL,
            minimumCount: 1
        ) == 1
        XCTAssertTrue(didRecordTurnStart)

        let pendingRequestCount = await client.debugPendingRequestCount()
        let timeoutTaskCount = await client.debugTimeoutTaskCount()
        XCTAssertEqual(pendingRequestCount, 1)
        XCTAssertEqual(timeoutTaskCount, 0)
        XCTAssertEqual(try recordedRequests(for: "turn/start", at: recordURL).count, 1)

        turnStart.cancel()
        do {
            _ = try await turnStart.value
            XCTFail("The ignored turn/start must remain pending until cancellation")
        } catch is CancellationError {
            // Expected: uncertain turn acceptance is not timed out or retried.
        } catch {
            XCTFail("Expected cancellation of the pending turn/start, got \(error)")
        }
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

    func testSchemaAlignedThreadRequestsOmitUndeclaredFieldsAndAcceptMissingGoal() async throws {
        let (startController, startRecordURL) = try await makeController(options: makeOptions())
        _ = try await startController.startOrResume(
            existing: nil,
            baseInstructions: "Agent",
            model: "gpt-test",
            reasoningEffort: "high"
        )
        let goal = try await startController.getThreadGoal()
        await startController.shutdown()

        let startParams = try recordedParams(for: "thread/start", at: startRecordURL)
        XCTAssertEqual(startParams["model"] as? String, "gpt-test")
        XCTAssertNil(startParams["effort"])
        XCTAssertNil(goal)

        for (rawStatus, expectedStatus) in [
            ("blocked", CodexNativeSessionController.ThreadGoalStatus.blocked),
            ("usageLimited", CodexNativeSessionController.ThreadGoalStatus.usageLimited)
        ] {
            let (goalController, _) = try await makeController(
                options: makeOptions(),
                goalStatus: rawStatus
            )
            _ = try await goalController.startOrResume(existing: nil, baseInstructions: "Agent")
            let parsedGoal = try await goalController.getThreadGoal()
            await goalController.shutdown()
            XCTAssertEqual(parsedGoal?.status, expectedStatus)
        }

        let (resumeController, resumeRecordURL) = try await makeController(options: makeOptions())
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "  existing-thread  ",
            rolloutPath: "  \n/tmp/existing-thread.jsonl\t ",
            model: nil,
            reasoningEffort: "high"
        )

        _ = try await resumeController.startOrResume(
            existing: existing,
            baseInstructions: "Agent",
            model: "gpt-test",
            reasoningEffort: "high"
        )
        await resumeController.shutdown()

        let params = try recordedParams(for: "thread/resume", at: resumeRecordURL)
        XCTAssertEqual(params["threadId"] as? String, "existing-thread")
        XCTAssertEqual(params["model"] as? String, "gpt-test")
        XCTAssertEqual(params["path"] as? String, "/tmp/existing-thread.jsonl")
        XCTAssertNil(params["effort"])
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

    func testResumeWithBlankPathOmitsPathAndSendsRequiredThreadID() async throws {
        let (controller, recordURL) = try await makeController(options: makeOptions())
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: " \n\t ",
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

    func testProtocolShapeRejectionsPreserveMessageAndUseManagedRuntimeGuidance() {
        for method in ["initialize", "thread/resume"] {
            for code in [-32601, -32602] {
                let error = CodexAppServerClient.ClientError.requestFailed(
                    .init(method: method, code: code, message: "server rejected request", data: nil)
                )

                XCTAssertTrue(error.localizedDescription.hasPrefix("server rejected request"))
                XCTAssertTrue(error.localizedDescription.contains("Reinstall or update RepoPrompt CE"))
                XCTAssertTrue(error.localizedDescription.contains("REPOPROMPT_CODEX_EXECUTABLE"))
                XCTAssertFalse(error.localizedDescription.contains("Update the installed Codex CLI"))
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
        ignoreMemoryModeRequests: Bool = false,
        goalStatus: String? = nil
    ) async throws -> (CodexNativeSessionController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerGoalConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(
            in: directory,
            recordURL: recordURL,
            ignoreMemoryModeRequests: ignoreMemoryModeRequests,
            goalStatus: goalStatus
        )
        let client = CodexAppServerClient()
        await client.updateConfig(
            CodexAppServerClient.Config(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                processLaunchDirectory: directory.path
            )
        )

        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        return (controller, recordURL)
    }

    private func makeFakeCodexAppServer(
        in directory: URL,
        recordURL: URL,
        ignoreMemoryModeRequests: Bool = false,
        ignoreInitializeRequests: Bool = false,
        ignoreTurnStartRequests: Bool = false,
        goalStatus: String? = nil
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import sys

        if sys.argv[1:] == ["--version"]:
            print("codex 0.144.6")
            raise SystemExit(0)

        record_path = \(String(reflecting: recordURL.path))
        ignore_memory_mode_requests = \(ignoreMemoryModeRequests ? "True" : "False")
        ignore_initialize_requests = \(ignoreInitializeRequests ? "True" : "False")
        ignore_turn_start_requests = \(ignoreTurnStartRequests ? "True" : "False")
        goal_status = \(goalStatus.map { String(reflecting: $0) } ?? "None")

        with open(record_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"method": "__process_args", "argv": sys.argv[1:], "cwd": os.getcwd()}) + "\\n")

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
            if method == "initialize" and ignore_initialize_requests:
                continue
            if method == "thread/memoryMode/set" and ignore_memory_mode_requests:
                continue
            if method == "turn/start" and ignore_turn_start_requests:
                continue
            if method == "thread/start":
                respond(request["id"], {"thread": {"id": "fresh-thread", "status": "idle", "turns": []}})
            elif method == "thread/resume":
                respond(request["id"], {"thread": {"id": params.get("threadId", "resumed-thread"), "status": "idle", "turns": []}})
            elif method == "turn/start":
                respond(request["id"], {"turn": {"id": "turn-1"}})
            elif method == "thread/goal/get" and goal_status is not None:
                respond(request["id"], {"goal": {
                    "threadId": "fresh-thread",
                    "objective": "Exercise schema statuses",
                    "status": goal_status,
                    "tokensUsed": 0,
                    "timeUsedSeconds": 0,
                    "createdAt": 1,
                    "updatedAt": 1
                }})
            else:
                respond(request["id"], {})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeController(
        executableURL: URL,
        initialProcessLaunchDirectory: String?,
        workspacePaths: CodexRuntimeWorkspacePaths,
        options: CodexNativeSessionController.Options
    ) async -> CodexNativeSessionController {
        let client = CodexAppServerClient()
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 5,
            processLaunchDirectory: initialProcessLaunchDirectory
        ))
        return CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePaths: workspacePaths,
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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
        var latestCount = (try? recordedRequests(for: method, at: recordURL).count) ?? 0
        while latestCount < minimumCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            latestCount = (try? recordedRequests(for: method, at: recordURL).count) ?? 0
        }
        return latestCount
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
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
