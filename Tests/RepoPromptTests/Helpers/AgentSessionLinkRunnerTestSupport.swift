import Foundation
@testable import RepoPromptApp
import XCTest

/// Runner-level harness for the cross-window oversight prompt supplement.
///
/// Builds the real `HeadlessAgentModeRunner` / `ACPIntegratedAgentModeRunner` (through
/// `AgentModeRunService`) with `AgentModeRunService.Hooks` whose session-link hooks are wired to a
/// **real** `AgentSessionLinkOutboundPromptClaimStore`. That is the whole point: these suites must
/// exercise the adapter call sites and their acceptance signals, not a re-implementation of them.
///
/// Deliberately avoids `MCPSharedServerTestLease`, window registration, and the view model's real
/// connection-policy installer: the lease is satisfied with a no-op installer and a granting
/// expected-PID armer, exactly as the run-service lifecycle suite does.
@MainActor
final class AgentSessionLinkRunnerHarness {
    let service: AgentModeRunService
    let host: AgentModeViewModel
    let claimStore = AgentSessionLinkOutboundPromptClaimStore()
    let recorder: LifecycleRecorder
    /// The exact hooks the service's runners use, so a test can also build one runner directly.
    ///
    /// The headless runner is not reachable through `AgentModeRunService.startRun` for any shipping
    /// agent kind (Codex, Claude-compatible, and ACP kinds each route elsewhere), so its adapter can
    /// only be exercised by constructing the runner itself.
    private(set) var hooks: AgentModeRunService.Hooks!
    private let headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory

    /// Live observer inventory the claim hook reads. Mutating this mid-run is how a test simulates a
    /// monitor being added or revoked while a dispatch is suspended.
    private(set) var inventory: AgentSessionLinkPromptInventory

    /// Runs immediately before `prepareForNextTurn()` on the ACP path, inside the window the old
    /// (buggy) composition point sat in. A test uses it to prove composition reads membership *after*
    /// that suspension.
    var onAttachmentsConsumed: (@MainActor () -> Void)?

    /// Runs while the message is being built, i.e. the last synchronous MainActor point before the
    /// headless runner's lease `providerInitializationStarted` hop. A test uses it to enqueue a
    /// membership change that lands *during* that suspension.
    var onHeadlessMessageBuilt: (@MainActor () -> Void)?

    /// System prompt the message builder stamps, so a test can cover both Claude-compatible
    /// (`nativeSystemPrompt`) and generic (`userMessageXML`, empty system) headless shapes.
    var stubSystemPrompt: String

    private(set) var acceptedClaims: [AgentSessionLinkOutboundPromptClaim] = []
    let observerSessionID = UUID()

    /// The observer incarnation these runs dispatch as.
    ///
    /// Claims are epoch-scoped, so the harness needs one stable identity rather than a bare session
    /// UUID; mutating `allowsSupplement` here is how a test simulates an eligibility transition.
    lazy var promptEpoch = AgentSessionLinkPromptEpoch(
        endpoint: DomainAgentSessionLinkEndpointIdentity(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: observerSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        ),
        allowsSupplement: true
    )

    /// Passive status batch offered to each claim, or `nil` for the membership-only default every
    /// pre-existing runner suite assumes.
    var passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?
    /// When set, provider-shaped dispatch IDs are rewritten to this wake identity exactly as the live
    /// view-model seam does. This lets adapter tests exercise required-claim refusal at the physical
    /// provider boundary without duplicating runner logic.
    var forcedAutoWakeID: UUID?

    init(
        stubSystemPrompt: String = "BASE INSTRUCTIONS",
        headlessProviderFactory: @escaping AgentModeViewModel.HeadlessProviderFactory,
        acpProviderFactory: @escaping AgentModeViewModel.ACPProviderFactory = { _, _ in nil },
        workspacePath: String = FileManager.default.currentDirectoryPath
    ) {
        self.stubSystemPrompt = stubSystemPrompt
        self.headlessProviderFactory = headlessProviderFactory
        let recorder = LifecycleRecorder()
        self.recorder = recorder
        inventory = AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: 0,
            items: []
        )

        let codexController = LifecycleNoopCodexController(recorder: recorder)
        let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
            // No MCP infrastructure in these suites: signal routing immediately so the bootstrap lease
            // resolves instead of waiting for a connection that will never arrive.
            if let runID { await MCPRoutingWaiter.notifyRouted(runID: runID) }
        }
        let serverEnabler: AgentModeViewModel.MCPServerEnabler = { true }
        let host = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in codexController },
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            connectionPolicyInstaller: policyInstaller,
            mcpServerEnabler: serverEnabler
        )
        self.host = host

        let dependencies = AgentModeRunService.Dependencies(
            windowID: 1,
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            },
            connectionPolicyInstaller: policyInstaller,
            expectedPIDPolicyArmer: { _ in true },
            mcpServerEnabler: serverEnabler,
            workspacePathProvider: { _ in workspacePath },
            codexCoordinator: host.test_codexCoordinator,
            claudeCoordinator: host.claudeCoordinator,
            shouldManageCodexTooling: false,
            providerRuntimePermissionResolver: { [bindingService = host.providerBindingService] agent, profile in
                bindingService.runtimePermission(for: agent, profile: profile)
            },
            bindPendingOracleReviewContext: { _, _ in },
            cancelMCPToolsForRun: { _, _ in },
            awaitNoActiveMCPTools: { _ in },
            activeAgentRunWaitQuery: { _ in false },
            childAgentRunWaitDrainTimeoutSeconds: 0.01
        )

        // `hooks` needs `self`, which is not fully initialized yet; build it through a box the
        // closures capture weakly.
        var harnessBox: AgentSessionLinkRunnerHarness?
        let hooks = AgentModeRunService.Hooks(
            usage: .init(
                estimateRuntimeTokens: { $0.count },
                addUserInputTokensToActiveNonCodexTurn: { _, _ in },
                startNonCodexTurnAccountingIfNeeded: { _, _ in },
                finalizeNonCodexTurnUsage: { _, _, _, _ in }
            ),
            attachments: .init(
                reserveAttachmentsForTurn: { _, _ in nil },
                markAttachmentsConsumed: { _, _ in
                    MainActor.assumeIsolated { harnessBox?.onAttachmentsConsumed?() }
                },
                stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
                consumeDeferredAttachmentCleanup: { _, _ in },
                finalizeAttachmentsForTurn: { _, _, _ in }
            ),
            presentation: .init(
                setAgentRunActive: { _, _ in },
                requestUIRefresh: { _, _ in },
                notifyAgentTurnComplete: { _ in }
            ),
            bindingObservation: .init(
                updateBindings: { _ in }
            ),
            queuedWorkRecovery: .init(
                restoreDraftText: { _, _, _, _ in }
            ),
            persistence: .init(
                scheduleSave: { _ in }
            ),
            transcript: .init(
                handleHeadlessStreamResult: { _, _, _, _ in },
                finalizeStreamingItems: { _ in },
                finalizePendingToolCalls: { _, _ in },
                finalizePendingToolCallsWithUpperBound: { _, _, _ in },
                flushPendingAssistantDelta: { _ in },
                clearPendingAssistantDelta: { _ in }
            ),
            providerInput: .init(
                buildHeadlessAgentMessage: { _, text, _, _ in
                    MainActor.assumeIsolated {
                        harnessBox?.onHeadlessMessageBuilt?()
                        return AgentMessage(
                            systemPrompt: harnessBox?.stubSystemPrompt ?? "",
                            userMessage: text
                        )
                    }
                },
                augmentUserMessageForProviderSend: { text, _, _, _ in text },
                stageResumeRecoveryHandoffIfNeeded: { _ in },
                prependPendingHandoffIfNeeded: { text, _ in text },
                recordPendingHandoffSendOutcome: { _, _ in },
                claimAgentSessionLinkPrompt: { _, dispatchID in
                    MainActor.assumeIsolated {
                        guard let harnessBox else {
                            // Family-first, exactly like the production fence: a reserved-family
                            // value that does not parse must never degrade to "nothing owed".
                            return dispatchID.isAutoWakeFamily
                                ? .requiredLaneBatchUnavailable
                                : .nothingOwed
                        }
                        let effectiveDispatchID = harnessBox.forcedAutoWakeID.map {
                            AgentSessionLinkPromptDispatchID.autoWake(wakeID: $0)
                        } ?? dispatchID
                        return harnessBox.claimStore.claimOutcome(
                            dispatchID: effectiveDispatchID,
                            epoch: harnessBox.promptEpoch,
                            inventory: harnessBox.inventory,
                            passiveNotices: harnessBox.passiveNotices
                        ) { request in
                            AgentSessionLinkPrompts.rendered(request)
                        }
                    }
                },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in },
                acceptAgentSessionLinkPrompt: { claim in
                    MainActor.assumeIsolated {
                        harnessBox?.claimStore.accept(claim)
                        harnessBox?.acceptedClaims.append(claim)
                    }
                }
            ),
            interactions: .init(
                cancelPendingQuestion: { _ in },
                cancelPendingApproval: { _ in },
                cancelPendingApplyEditsReview: { _, _ in },
                cancelPendingWorktreeMergeReview: { _, _ in }
            ),
            terminalSettlement: .init(
                prepareTerminalPublication: { _ in },
                makeTerminalPublicationEnvelope: { _, _, _, _, _ in nil },
                publishTerminalCommit: { _, _, _ in .accepted(successorEpoch: nil) }
            ),
            continuation: .init(
                startFollowUpRun: { _, _ in },
                signalMCPInstructionDelivered: { _ in }
            )
        )
        self.hooks = hooks
        service = AgentModeRunService(
            dependencies: dependencies,
            hooks: hooks,
            toolTrackingHooks: .noOp
        )
        harnessBox = self
    }

    /// A `HeadlessAgentModeRunner` wired to the same hooks and provider factory as the service.
    func makeHeadlessRunner() -> HeadlessAgentModeRunner {
        HeadlessAgentModeRunner(
            headlessProviderFactory: headlessProviderFactory,
            hooks: hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier()
        )
    }

    /// Bootstrap lease with every side effect stubbed out: no MCP server, no connection policy, and
    /// routing signalled immediately so `acquire()` cannot park.
    nonisolated func makeLease(runID: UUID, tabID: UUID) -> MCPBootstrapLease {
        MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: tabID,
                clientName: "RepoPromptCE",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "monitor-runner-test",
                ttl: 60,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false
            ),
            mcpServerEnabler: { true },
            policyInstaller: { spec in
                await MCPRoutingWaiter.notifyRouted(runID: spec.runID)
            },
            expectedPIDPolicyArmer: { _ in true },
            policyClearer: { _ in }
        )
    }

    /// Publishes a new observer membership revision, like the runtime bridge does.
    func publishInventory(revision: UInt64, targetCount: Int) {
        inventory = AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: (0 ..< targetCount).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: UUID(
                        uuidString: String(format: "0000000%d-0000-0000-0000-00000000FACE", index)
                    )!,
                    displayName: "Target \(index)",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                )
            }
        )
    }

    func makeSession(agent: AgentProviderKind) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        return session
    }
}

// MARK: - Headless provider fake

/// Captures the exact `AgentMessage` that crossed `streamAgentMessage`, and can fail stream creation.
actor AgentSessionLinkCapturingHeadlessProvider: HeadlessAgentProvider {
    struct StreamCreationFailure: Error {}

    private(set) var messages: [AgentMessage] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    var messageCount: Int {
        messages.count
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID _: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        messages.append(message)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw StreamCreationFailure()
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func dispose() async {}
}

// MARK: - ACP provider fake

/// Records the `AgentMessage` the real `ACPAgentSessionController` passes to `buildPromptBlocks`,
/// which is exactly the message that reached `controller.prompt`.
final class AgentSessionLinkCapturingACPProvider: ACPAgentProvider, @unchecked Sendable {
    let providerID: ACPProviderID
    let commandPath: String
    var environment: [String: String] = [:]

    private let lock = NSLock()
    private var captured: [AgentMessage] = []

    init(providerID: ACPProviderID, commandPath: String, environment: [String: String] = [:]) {
        self.providerID = providerID
        self.commandPath = commandPath
        self.environment = environment
    }

    var promptedMessages: [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
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
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request _: ACPRunRequest
    ) throws -> [[String: Any]] {
        lock.lock()
        captured.append(message)
        lock.unlock()
        return [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

// MARK: - Fake ACP server

enum AgentSessionLinkACPServerScript {
    /// Minimal ACP server. `ACP_FAIL_PROMPTS_CONTAINING` makes `session/prompt` return an error when
    /// the prompt text contains that marker, which is how a test forces a failed steer.
    static func write(to directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("monitor_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        fail_marker = os.environ.get("ACP_FAIL_PROMPTS_CONTAINING")
        current_model = "model-a"
        current_mode = "ask"

        def config_options():
            # The controller refuses to run against a runtime that does not advertise a modern
            # session-mode select, so both selects are required here.
            return [
                {
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": current_model,
                    "options": [{"value": "model-a", "name": "Model A"}]
                },
                {
                    "id": "mode",
                    "name": "Session Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": current_mode,
                    "options": [
                        {"value": "ask", "name": "Ask"},
                        {"value": "repoprompt_acp", "name": "RepoPrompt"},
                        {"value": "repoprompt_acp_full_access", "name": "RepoPrompt Full Access"}
                    ]
                }
            ]

        def respond(request_id, result=None):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result or {}}), flush=True)

        def respond_error(request_id, message):
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32000, "message": message}
            }), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/new":
                respond(request.get("id"), {
                    "sessionId": "monitor-acp-session",
                    "configOptions": config_options()
                })
            elif method == "session/set_config_option":
                if params.get("configId") == "model":
                    current_model = params.get("value")
                elif params.get("configId") == "mode":
                    current_mode = params.get("value")
                respond(request.get("id"), {"configOptions": config_options()})
            elif method == "session/prompt":
                text = json.dumps(params)
                if fail_marker and fail_marker in text:
                    respond_error(request.get("id"), "prompt rejected")
                else:
                    respond(request.get("id"), {
                        "stopReason": "end_turn",
                        "usage": {"inputTokens": 1, "outputTokens": 1}
                    })
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }
}
